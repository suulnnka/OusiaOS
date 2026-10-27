//! ELF64 加载器（静态可执行文件）
//!
//! 教学要点：
//!   - execve 的核心工作：把 ELF 文件里的 PT_LOAD 段按 p_vaddr
//!     映射进用户地址空间，文件部分拷贝数据（filesz），其余清零（bss）
//!   - 我们的加载约定：数据先写进物理页帧（借助内核直接映射区），
//!     再把该帧映射到用户虚拟地址——这样无需切换 CR3 就能填内容
//!
//! 支持范围：ET_EXEC 静态 ELF64（小端 x86-64），不支持 PIE/动态链接

const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");

pub const Image = struct {
    entry: usize, // 用户入口 RIP
    brk: usize, // 初始程序断点（bss 结束向上取整到页）
};

const PT_LOAD = 1;

/// 把 ELF 镜像加载进 pml4（用户地址空间）。失败返回 null。
pub fn load(pml4: usize, data: []const u8) ?Image {
    if (data.len < 64) return null;
    const bytes: [*]const u8 = data.ptr;

    // ELF 头检查
    if (bytes[0] != 0x7F or bytes[1] != 'E' or bytes[2] != 'L' or bytes[3] != 'F') return null;
    if (bytes[4] != 2) return null; // ELFCLASS64
    if (bytes[5] != 1) return null; // 小端
    if (bytes[6] != 1) return null; // EV_CURRENT
    const e_type = readU16(bytes, 16);
    if (e_type != 2) return null; // ET_EXEC（不支持 PIE/共享对象）
    const e_machine = readU16(bytes, 18);
    if (e_machine != 0x3E) return null; // x86-64

    const e_entry = readU64(bytes, 24);
    const e_phoff = readU64(bytes, 32);
    const e_phentsize = readU16(bytes, 54);
    const e_phnum = readU16(bytes, 56);

    var max_end: usize = 0;
    var ok = true;

    var i: usize = 0;
    while (i < e_phnum) : (i += 1) {
        const ph: [*]const u8 = @ptrFromInt(@intFromPtr(bytes) + e_phoff + i * e_phentsize);
        if (readU32(ph, 0) != PT_LOAD) continue;

        const p_offset = readU64(ph, 8);
        const p_vaddr = readU64(ph, 16);
        const p_filesz = readU64(ph, 32);
        const p_memsz = readU64(ph, 40);
        if (p_vaddr < 0x1000) return null; // 不允许映射第 0 页（便于捕获空指针）

        // 逐页：分配→清零→映射→拷贝属于本页的文件内容
        var va: u64 = p_vaddr & ~@as(u64, 0xFFF);
        const vend: u64 = (p_vaddr + p_memsz + 0xFFF) & ~@as(u64, 0xFFF);
        while (va < vend) : (va += 0x1000) {
            if (!vmm.isMapped(pml4, @intCast(va))) {
                const frame = pmm.allocFrame() orelse {
                    ok = false;
                    break;
                };
                const page: *[4096]u8 = @ptrFromInt(vmm.physToVirt(frame));
                @memset(page, 0);
                if (!vmm.mapPage(pml4, @intCast(va), frame, vmm.P | vmm.W | vmm.U)) {
                    pmm.freeFrame(frame);
                    ok = false;
                    break;
                }
            }
            // 本页中属于文件内容的区间 [seg_lo, seg_hi)
            const seg_lo: u64 = @max(p_vaddr, va);
            const seg_hi: u64 = @min(va + 4096, p_vaddr + p_filesz);
            if (seg_hi > seg_lo) {
                const page: [*]u8 = @ptrFromInt(userPageVirt(pml4, @intCast(va)));
                const n: usize = @intCast(seg_hi - seg_lo);
                const dst: usize = @intCast(seg_lo - va);
                const src: usize = @intCast(p_offset + (seg_lo - p_vaddr));
                @memcpy(page[dst .. dst + n], data[src .. src + n]);
            }
        }
        if (!ok) break;

        if (p_vaddr + p_memsz > max_end) max_end = p_vaddr + p_memsz;
    }

    if (!ok) {
        vmm.destroyUserSpace(pml4);
        return null;
    }

    return .{ .entry = e_entry, .brk = (max_end + 0xFFF) & ~@as(usize, 0xFFF) };
}

/// 取用户页的内核可写视角：从页表读出物理帧，再经直接映射区访问。
/// （当前 CR3 是旧地址空间，不能直接解引用新空间里的用户地址）
fn userPageVirt(pml4: usize, vaddr: usize) usize {
    var t = vmm.tableOf(pml4);
    inline for (.{ (vaddr >> 39) & 511, (vaddr >> 30) & 511, (vaddr >> 21) & 511 }) |idx| {
        t = vmm.tableOf(t[idx] & 0x000F_FFFF_FFFF_F000);
    }
    const frame = t[(vaddr >> 12) & 511] & 0x000F_FFFF_FFFF_F000;
    return vmm.physToVirt(frame);
}

fn readU32(p: [*]const u8, off: usize) u32 {
    return @as(u32, p[off]) | (@as(u32, p[off + 1]) << 8) | (@as(u32, p[off + 2]) << 16) | (@as(u32, p[off + 3]) << 24);
}
fn readU16(p: [*]const u8, off: usize) u16 {
    return @as(u16, p[off]) | (@as(u16, p[off + 1]) << 8);
}
fn readU64(p: [*]const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        v = (v << 8) | p[off + i];
    }
    return v;
}
