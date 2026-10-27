//! ZOS —— 用 Zig 编写的 x86_64 教学操作系统内核
//!
//! 这是内核主入口（zos_start），由 boot.S 在开启长模式后调用。
//! 启动流程：
//!   GRUB → boot.S(32位入口→页表→长模式) → zos_start()
//!          → 控制台 → multiboot 信息 → GDT/TSS → IDT → PIC → PIT
//!          → (内存管理 → 文件系统 → 进程/调度 → 用户态 init/shell)

const std = @import("std");
const console = @import("console.zig");
const multiboot = @import("multiboot.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
const keyboard = @import("keyboard.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const tarfs = @import("tarfs.zig");
const vfs = @import("vfs.zig");
const proc = @import("proc.zig");

pub const KERNEL_VIRT_BASE: usize = 0xFFFF_FFFF_8000_0000;

// ---- 内核 panic 处理：打印消息后停机 ----
fn kernPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    console.kprintf("\n!!! KERNEL PANIC: {s}\n", .{msg});
    if (ret_addr) |ra| console.kprintf("    at {x}\n", .{ra});
    halt();
}
pub const panic = std.debug.FullPanic(kernPanic);

/// 内核入口（C 调用约定：rdi=magic, rsi=boot_info 高端虚拟地址）
export fn zos_start(magic: u32, mbi_virt: usize) callconv(.c) noreturn {
    // 在第一次触碰屏幕【之前】探测 VBE 帧缓冲：图形模式下 0xB8000
    // 不再是文本屏，console 必须从一开始就知道要不要走 VGA 文本路径
    const gui_mode = multiboot.sniffFramebuffer(mbi_virt);
    console.init(gui_mode);

    console.kprintf("\nZOS 0.2.0 -- a tiny teaching kernel in Zig\n", .{});
    console.kprintf("boot: 64-bit long mode OK\n", .{});

    if (magic != multiboot.MB2_BOOTLOADER_MAGIC) {
        console.kprintf("boot: bad multiboot2 magic {x}, halt.\n", .{magic});
        halt();
    }
    multiboot.init(mbi_virt);
    console.kprintf("boot: usable memory = {d} MB\n", .{multiboot.usable_bytes / 1024 / 1024});

    // ---- 中断体系 ----
    gdt.init();
    console.kprintf("boot: gdt/tss loaded\n", .{});
    idt.init();
    pic.init();
    pit.init();
    keyboard.init();
    console.kprintf("boot: idt+pic+pit(100Hz)+keyboard ready\n", .{});

    // 开 IRQ0(定时器) / IRQ1(键盘) / IRQ2(级联)
    pic.unmask(0);
    pic.unmask(1);
    pic.unmask(2);

    // ---- 内存管理（提前：网络初始化依赖 vmm 的 MMIO 映射）----
    pmm.init();
    vmm.init();
    console.kprintf("boot: pmm {d} free frames ({d} MB), cr3={x}\n", .{
        pmm.freeFrames(), pmm.freeFrames() * 4 / 1024, vmm.readCr3(),
    });
    if (pmm.selfTest()) {
        console.kprintf("boot: pmm alloc/write/free self-test OK\n", .{});
    } else {
        console.kprintf("boot: pmm self-test FAILED\n", .{});
    }

    // ---- 图形（合成器 + 桌面/任务栏）----
    // 依赖 vmm 的 MMIO 映射；必须在 sti 之前完成（无锁的中断驱动模型）
    @import("gui.zig").init();

    // ---- 网络 ----
    // QEMU 的 e1000 模型在写 RCTL 后武装 1 秒 flush 定时器，期间收包
    // 在 QEMU 网络层排队不投递——下面的 tick 演示等待恰好把它等过去
    _ = @import("net.zig").init();

    // ---- 音频（AC'97；失败不致命，无后端时保持静音）----
    _ = @import("audio.zig").init();

    // 开中断！从这一刻起内核是被中断驱动的
    asm volatile ("sti");
    console.kprintf("boot: interrupts enabled\n", .{});

    // 等待 2 秒（每秒一报），验证定时器中断确实在跑
    var last: u64 = pit.ticks;
    var reports: u64 = 0;
    while (reports < 2) {
        if (pit.ticks >= last + 100) {
            last = pit.ticks;
            reports += 1;
            console.kprintf("tick: uptime {d}ms\n", .{pit.uptimeMs()});
        }
        asm volatile ("hlt");
    }

    // 网络自检（此刻 QEMU 的 RX flush 定时器已过期）
    if (@import("net.zig").ready()) {
        console.kprintf("boot: net selftest ping 10.0.2.2 -> {d} ms\n", .{@import("net.zig").ping(0x0A00_0202, 1)});
    }

    // ---- 文件系统 ----
    if (tarfs.init()) {
        vfs.init();
        console.kprintf("boot: vfs ready\n", .{});

        // 列根目录
        console.kprintf("boot: ls /\n", .{});
        vfs.listDir(vfs.ROOT_NODE, {}, struct {
            fn cb(_: void, name: []const u8, _: usize) void {
                console.kprintf("  {s}\n", .{name});
            }
        }.cb);

        // 读 /etc/motd
        if (vfs.resolve("/etc/motd", "/")) |node| {
            var buf: [512]u8 = undefined;
            const n = vfs.read(node, 0, &buf);
            if (n > 0) {
                console.kprintf("boot: cat /etc/motd ({d} bytes):\n", .{n});
                for (buf[0..@intCast(n)]) |c| console.putChar(c);
                console.kprintf("\n", .{});
            }
        } else {
            console.kprintf("boot: /etc/motd not found!\n", .{});
        }
    } else {
        console.kprintf("boot: continue without filesystem\n", .{});
    }

    // ---- 真磁盘：ATA PIO + ext2 挂载到 /mnt（失败不致命，无盘可继续）----
    // tarfs（initrd，RAM）之上挂 ext2（磁盘，可读写）——经典的
    // "内存根文件系统 + 挂载真磁盘"两段式
    if (@import("ata.zig").init() and @import("ext2.zig").mount() and vfs.mountExt2("/mnt")) {
        console.kprintf("boot: ext2 mounted at /mnt\n", .{});
        console.kprintf("boot: ls /mnt\n", .{});
        if (vfs.resolve("/mnt", "/")) |mnt| {
            vfs.listDir(mnt, {}, struct {
                fn cb(_: void, name: []const u8, _: usize) void {
                    console.kprintf("  {s}\n", .{name});
                }
            }.cb);
        }
        if (vfs.resolve("/mnt/hello.txt", "/")) |node| {
            var buf: [128]u8 = undefined;
            const n = vfs.read(node, 0, &buf);
            if (n > 0) {
                console.kprintf("boot: cat /mnt/hello.txt:\n", .{});
                for (buf[0..@intCast(n)]) |c| console.putChar(c);
                console.kprintf("\n", .{});
            }
        }
    } else {
        console.kprintf("boot: no ext2 disk (run scripts/mkdisk.sh, QEMU needs -drive)\n", .{});
    }

    // GUI 的"晚初始化"：读 /etc/zos.conf 壁纸/屏保设置 + 开机音
    // （WAV/ramfs 都依赖上面的文件系统就绪）
    @import("gui.zig").lateInit();

    // ---- 网络（在进程诞生前完成：MMIO 映射随内核半区共享）----
    // ---- 进程与调度 ----
    proc.init();
    if (proc.spawnInit()) {
        console.kprintf("boot: init process spawned, entering scheduler\n", .{});
        console.kprintf("\n", .{});
        proc.scheduler(); // 永不返回
    }

    console.kprintf("\nboot: no user process -- halting\n\n", .{});
    halt();
}

fn halt() noreturn {
    while (true) asm volatile ("hlt");
}
