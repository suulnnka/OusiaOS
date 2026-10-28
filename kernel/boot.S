/*
 * OusiaOS 引导阶段（boot.S）
 *
 * 运行环境：GRUB 按 Multiboot2 协议加载内核后，CPU 处于
 *   - 32 位保护模式（未开分页）
 *   - EAX = 0x36d76289（multiboot2 魔数）
 *   - EBX = boot 信息结构的【物理】地址
 *
 * 本文件任务（对应"操作系统启动"教学主线）：
 *   1. 提供 Multiboot2 头，让 GRUB 认识内核镜像
 *   2. 保存 GRUB 传入的信息
 *   3. 建立引导页表（恒等映射 + 高端映射，2MB 大页）
 *   4. 开启 PAE → 长模式（EFER.LME）→ 分页（CR0.PG）
 *   5. 远跳进入 64 位模式，切换到内核栈，跳入 Zig 内核入口 ousia_start()
 */

.set MB2_HDR_MAGIC,   0xE85250D6
.set PAGE_PRESENT,    0x1
.set PAGE_WRITE,      0x2

/* ---------------- Multiboot2 头 ----------------
 * 必须位于镜像最前 32KB 且 8 字节对齐；GRUB 按它加载 ELF 并跳到入口。 */
.section .multiboot2, "a"
.align 8
mb2_header:
    .long MB2_HDR_MAGIC                 /* magic                  */
    .long 0                             /* architecture: i386     */
    .long mb2_end - mb2_header          /* 头总长度               */
    .long -(MB2_HDR_MAGIC + 0 + (mb2_end - mb2_header))  /* checksum */
    /* framebuffer 头标签：向 GRUB 声明"我要图形模式"。
     * 没有 it 的话 GRUB 按 Multiboot2 默认留在 EGA 文本模式，
     * 只给 type=2 的文本 framebuffer 标签（GUI 退回文本模式）。
     * 注意：标签按 8 字节对齐排布——本标签 20 字节，后面的结束
     * 标签必须 .align 8 落在偏移 40，否则 GRUB 标签遍历会错位卡死。 */
    .align 8
    .short 5                            /* tag type = framebuffer */
    .short 0                            /* flags                  */
    .long 20                            /* size = 8 + 3*4         */
    .long 640                           /* width                  */
    .long 480                           /* height                 */
    .long 32                            /* depth (bpp)            */
    /* 结束标签（type=0） */
    .align 8
    .word 0
    .word 0
    .long 8
mb2_end:

/* ---------------- 引导数据 ---------------- */
.section .boot.data, "aw"
.align 8
boot_gdt:
    .quad 0x0000000000000000            /* 0x00: 空描述符          */
    .quad 0x00AF9A000000FFFF            /* 0x08: 64位代码段 L=1,D=0 */
    .quad 0x00CF92000000FFFF            /* 0x10: 数据段            */
boot_gdt_end:
boot_gdtr:
    .short boot_gdt_end - boot_gdt - 1  /* limit；基址在运行时填入 */
    .long 0

.section .boot.bss, "aw", @nobits
.align 4
mb2_magic_saved:  .space 4              /* GRUB 传入的魔数         */
mb2_info_saved:   .space 4              /* boot 信息块物理地址     */

.align 4096
boot_pml4:      .space 4096             /* 四级页表（PML4）        */
boot_pdpt_low:  .space 4096             /* PML4[0]   → 恒等映射    */
boot_pdpt_high: .space 4096             /* PML4[511] → 高端映射    */
boot_pd:        .space 4096             /* 512 × 2MB 大页 = 1GB    */

.align 16
boot_stack:     .space 16384            /* 32 位阶段的临时栈       */
boot_stack_top:

/* ---------------- 32 位入口 ---------------- */
.section .boot.text, "ax"
.code32

.extern ousia_start                       /* Zig 内核入口（高地址）  */
.extern kernel_stack_top                /* 链接脚本定义的内核主栈  */

.global _start
_start:
    cli
    cld
    movl  $boot_stack_top, %esp
    xorl  %ebp, %ebp

    /* 保存 GRUB 传入的 multiboot2 信息 */
    movl  %eax, mb2_magic_saved
    movl  %ebx, mb2_info_saved

    /* ---- 检查 CPU 是否支持长模式（CPUID 0x80000001 → EDX bit29 = LM）---- */
    movl  $0x80000000, %eax
    cpuid
    cmpl  $0x80000001, %eax
    jb    .no_longmode
    movl  $0x80000001, %eax
    cpuid
    testl $0x20000000, %edx
    jz    .no_longmode

    /* ---- 建立引导页表：物理前 1GB 用 512 个 2MB 大页 ----
     * PD 第 i 项 = 物理地址 i*2MB，标志 P|RW|PS(0x80) = 0x83 */
    movl  $boot_pd, %edi
    xorl  %ecx, %ecx
    movl  $0x00000083, %eax
.fill_pd:
    movl  %eax, (%edi)
    movl  $0, 4(%edi)                   /* 高 32 位清零（地址 < 4GB）*/
    addl  $0x00200000, %eax
    addl  $8, %edi
    incl  %ecx
    cmpl  $512, %ecx
    jne   .fill_pd

    /* PDPT_low[0] = PD  —— 供 PML4[0]（虚拟地址 0x0 起的恒等映射）*/
    movl  $boot_pd, %eax
    orl   $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl  %eax, boot_pdpt_low
    movl  $0, boot_pdpt_low + 4

    /* PDPT_high[510] = PD —— 供 PML4[511]（0xFFFFFFFF80000000 起的高端映射）
     * 0xFFFFFFFF80000000 正好落在 PML4[511] 覆盖的 512GB 中第 510 个 1GB 处 */
    movl  $boot_pd, %eax
    orl   $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl  %eax, boot_pdpt_high + 8*510
    movl  $0, boot_pdpt_high + 8*510 + 4

    /* PML4[0] = PDPT_low，PML4[511] = PDPT_high */
    movl  $boot_pdpt_low, %eax
    orl   $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl  %eax, boot_pml4
    movl  $0, boot_pml4 + 4

    movl  $boot_pdpt_high, %eax
    orl   $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl  %eax, boot_pml4 + 8*511
    movl  $0, boot_pml4 + 8*511 + 4

    /* ---- 开启分页与长模式 ---- */
    movl  $boot_pml4, %eax
    movl  %eax, %cr3                    /* 载入页表基址            */

    movl  %cr4, %eax
    orl   $0x6A0, %eax                   /* PAE(5)|PGE(7)|OSFXSR(9)|OSXMMEXCPT(10)
                                             —— OSFXSR 必须置 1，否则 SSE 指令触发 #UD */
    movl  %eax, %cr4

    movl  $0xC0000080, %ecx             /* IA32_EFER MSR           */
    rdmsr
    orl   $0x100, %eax                  /* LME(bit8)：开启长模式   */
    wrmsr

    movl  %cr0, %eax
    orl   $0x80000001, %eax             /* PG(bit31) | PE(bit0)    */
    movl  %eax, %cr0                    /* 从此刻起进入 IA-32e 兼容模式 */

    /* ---- 载入含 64 位代码段的 GDT，远跳进入 64 位 ---- */
    movl  $boot_gdtr, %eax
    movl  $boot_gdt, %ecx
    movl  %ecx, 2(%eax)                 /* 填 GDTR 基址            */
    lgdt  (%eax)
    ljmp  $0x08, $.Lcode64

.no_longmode:
    /* CPU 不支持长模式：向 VGA 文本缓冲区(0xB8000)写 '!' 后死循环 */
    movl  $0xB8000, %edi
    movw  $0x4F21, (%edi)               # 白底红字 '!'
1:  hlt
    jmp  1b

/* ---------------- 64 位部分（仍在低地址执行，靠恒等映射）---------------- */
.code64
.Lcode64:
    /* 重载数据段寄存器 */
    mov   $0x10, %eax
    mov   %eax, %ds
    mov   %eax, %es
    mov   %eax, %ss
    xor   %eax, %eax
    mov   %eax, %fs
    mov   %eax, %gs

    /* 切换到内核主栈（高端地址） */
    movabsq $kernel_stack_top, %rsp

    /* 准备 ousia_start(magic, boot_info_virt) 参数（SysV: rdi, rsi）*/
    movl   mb2_magic_saved, %edi        /* movl 写 edi 自动零扩展   */
    movl   mb2_info_saved, %esi
    movabsq $0xFFFFFFFF80000000, %r8
    addq   %r8, %rsi                    /* 物理地址 → 高端虚拟地址  */

    movabsq $ousia_start, %rax
    call   *%rax                        /* 进入 Zig 世界，不再返回  */

1:  hlt
    jmp  1b
