//! Multiboot2 引导信息解析
//!
//! GRUB 把一块"标签链表"（tag list）通过 EBX 传给内核：
//!   [u32 总长度][u32 保留][Tag...][结束 Tag(type=0)]
//! 每个 Tag: { u32 type; u32 size; ...payload... }，按 8 字节对齐排布。
//!
//! 教学要点：从引导协议拿到的两类关键信息——
//!   1. 内存映射（mmap, type=6）：哪些物理内存可用 → 物理页帧分配器
//!   2. 模块（module, type=3）：GRUB 替我们加载的文件 → initrd(tarfs)

const console = @import("console.zig");
const std = @import("std");

pub const MB2_BOOTLOADER_MAGIC: u32 = 0x36d76289;

pub const Tag = extern struct {
    type: u32,
    size: u32,
};

pub const MmapEntry = extern struct {
    base_addr: u64,
    length: u64,
    entry_type: u32,
    _reserved: u32,
};

pub const MmapTag = extern struct {
    type: u32,
    size: u32,
    entry_size: u32,
    entry_version: u32,
};

pub const ModuleTag = extern struct {
    type: u32,
    size: u32,
    mod_start: u32, // 物理地址
    mod_end: u32, // 物理地址（不含）
    // 之后紧跟以 NUL 结尾的命令行字符串
};

const TagType = enum(u32) {
    end = 0,
    module = 3,
    memory_map = 6,
    framebuffer = 8, // GRUB 设置 gfxpayload 后提供：线性帧缓冲信息
    _,
};

// ---- 帧缓冲（VBE 图形模式）信息，gui.zig 使用 ----

pub var fb_present: bool = false;
pub var fb_addr: u64 = 0;
pub var fb_pitch: u32 = 0;
pub var fb_width: u32 = 0;
pub var fb_height: u32 = 0;
pub var fb_bpp: u8 = 0;
pub var fb_type: u8 = 0; // 0=indexed 1=RGB 2=EGA 文本
// RGB 布局（type==1 有效）：各通道的字段位置与位宽
pub var fb_r_pos: u8 = 0;
pub var fb_r_len: u8 = 0;
pub var fb_g_pos: u8 = 0;
pub var fb_g_len: u8 = 0;
pub var fb_b_pos: u8 = 0;
pub var fb_b_len: u8 = 0;

/// gui.zig 支持的模式：640x480x32 RGB（Win3.1 经典分辨率）。
/// console 也用它决定是否跳过 VGA 文本路径（VBE 模式下写 0xB8000
/// 会往帧缓冲开头画垃圾）。
pub fn framebufferUsable() bool {
    return fb_present and fb_type == 1 and fb_bpp == 32 and
        fb_width == 640 and fb_height == 480 and
        fb_r_len == 8 and fb_g_len == 8 and fb_b_len == 8;
}

/// 在 console 初始化【之前】静默扫描 framebuffer 标签（不打印），
/// 让控制台从一开始就知道该不该写 VGA 文本显存。
pub fn sniffFramebuffer(virt: usize) bool {
    parseFramebufferTag(virt);
    return framebufferUsable();
}

/// 解析 framebuffer 标签（type=8）。GRUB 的实际布局：
///   u32 type; u32 size; u64 addr; u32 pitch; u32 width; u32 height;
///   u8 bpp; u8 type; [2 字节对齐填充]; color_info[6]
/// 注意颜色信息在偏移 32 而非 30：联合体按 4 字节对齐垫了 2 字节
/// （tag 实测 size=38 = 30 + 2 + 6，踩坑现场）
fn parseFramebufferTag(virt: usize) void {
    var p = virt + 8;
    while (true) {
        const tag: *align(1) const Tag = @ptrFromInt(p);
        if (tag.type == @intFromEnum(TagType.end)) break;
        if (tag.type == @intFromEnum(TagType.framebuffer)) {
            const b: [*]const u8 = @ptrFromInt(p);
            fb_present = true;
            fb_addr = readU64(b, 8);
            fb_pitch = readU32(b, 16);
            fb_width = readU32(b, 20);
            fb_height = readU32(b, 24);
            fb_bpp = b[28];
            fb_type = b[29];
            if (fb_type == 1 and tag.size >= 38) {
                fb_r_pos = b[32];
                fb_r_len = b[33];
                fb_g_pos = b[34];
                fb_g_len = b[35];
                fb_b_pos = b[36];
                fb_b_len = b[37];
            }
            break;
        }
        p += (tag.size + 7) & ~@as(usize, 7);
    }
}

fn readU32(b: [*]const u8, off: usize) u32 {
    return @as(u32, b[off]) | (@as(u32, b[off + 1]) << 8) |
        (@as(u32, b[off + 2]) << 16) | (@as(u32, b[off + 3]) << 24);
}

fn readU64(b: [*]const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        v = (v << 8) | b[off + i];
    }
    return v;
}

/// 第一个模块（约定为 initrd tar 镜像）的物理地址范围
pub var initrd_start: usize = 0;
pub var initrd_end: usize = 0;

/// 可用物理内存总量（mmap type=1 累加）
pub var usable_bytes: u64 = 0;

/// 缓存的 usable 区域列表（供 pmm 初始化用）
const MAX_REGIONS = 16;
var regions_buf: [MAX_REGIONS]MmapEntry = undefined;
var regions_len: usize = 0;

/// 返回缓存的可用内存区域
pub fn usableRegions() []const MmapEntry {
    return regions_buf[0..regions_len];
}

/// 解析并缓存引导信息。virt = 信息块的高端虚拟地址。
pub fn init(virt: usize) void {
    var p = virt + 8; // 跳过 u32 total_size + u32 reserved
    while (true) {
        const tag: *align(1) const Tag = @ptrFromInt(p);
        if (tag.type == @intFromEnum(TagType.end)) break;

        switch (@as(TagType, @enumFromInt(tag.type))) {
            .memory_map => {
                const mm: *align(1) const MmapTag = @ptrFromInt(p);
                var q = p + @sizeOf(MmapTag);
                const endp = p + tag.size;
                while (q + mm.entry_size <= endp) : (q += mm.entry_size) {
                    const e: *align(1) const MmapEntry = @ptrFromInt(q);
                    const kind_str = switch (e.entry_type) {
                        1 => "usable",
                        2 => "reserved",
                        3 => "ACPI reclaimable",
                        4 => "NVS",
                        5 => "bad memory",
                        else => "unknown",
                    };
                    console.kprintf("  [mmap] base={x} len={x} {s}\n", .{
                        e.base_addr, e.length, kind_str,
                    });
                    if (e.entry_type == 1) {
                        usable_bytes += e.length;
                        if (regions_len < MAX_REGIONS) {
                            regions_buf[regions_len] = e.*;
                            regions_len += 1;
                        }
                    }
                }
            },
            .module => {
                const m: *align(1) const ModuleTag = @ptrFromInt(p);
                const cmdline: [*:0]const u8 = @ptrFromInt(p + @sizeOf(ModuleTag));
                console.kprintf("  [module] {s}: phys [{x}, {x}) size={d}KB\n", .{
                    std.mem.span(cmdline), m.mod_start, m.mod_end, (m.mod_end - m.mod_start) / 1024,
                });
                if (initrd_start == 0) {
                    initrd_start = m.mod_start;
                    initrd_end = m.mod_end;
                }
            },
            else => {},
        }
        p += (tag.size + 7) & ~@as(usize, 7); // 标签按 8 字节对齐步进
    }
}
