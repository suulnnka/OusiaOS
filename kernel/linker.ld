/*
 * ZOS 内核链接脚本
 *
 * 内存布局（教学要点）：
 *
 *   物理地址                 虚拟地址
 *   ─────────────────────   ─────────────────────────────
 *   0x0000000000100000  →   0x0000000000100000   .boot（引导段，VMA==LMA）
 *   0x0000000000200000  →   0xFFFFFFFF80200000   内核主体（高端映射）
 *   X                   →   0xFFFFFFFF80000000+X 直接映射区起点（phys+0xFFFFFFFF80000000）
 *
 * 引导段里的代码在"开分页之前"就要运行，因此必须位于低物理地址；
 * 内核主体链接在高端地址 0xFFFFFFFF80000000（直接映射区起点），
 * 引导页表用 2MB 大页同时建立"恒等映射 + 高端映射"完成交接。
 */

ENTRY(_start)

KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;

SECTIONS
{
    /* ============ 引导段：物理 1MB 起，VMA == LMA ============ */
    . = 1M;

    .boot : {
        KEEP(*(.multiboot2))
        *(.boot.text)
        *(.boot.data)
        *(.boot.bss)
    }

    /* ============ 内核主体：高端虚拟地址 ============ */
    . = ALIGN(2M);
    kernel_phys_start = .;
    . += KERNEL_VIRT_BASE;

    .text : AT(ADDR(.text) - KERNEL_VIRT_BASE) ALIGN(4K) {
        kernel_start = .;
        *(.text .text.*)
    }

    .rodata : AT(ADDR(.rodata) - KERNEL_VIRT_BASE) ALIGN(4K) {
        *(.rodata .rodata.*)
    }

    .data : AT(ADDR(.data) - KERNEL_VIRT_BASE) ALIGN(4K) {
        *(.data .data.*)
    }

    .bss : AT(ADDR(.bss) - KERNEL_VIRT_BASE) ALIGN(4K) {
        *(.bss .bss.*)
        *(COMMON)

        /* 内核主栈（64KB） */
        . = ALIGN(16);
        kernel_stack_bottom = .;
        . += 64K;
        kernel_stack_top = .;

        kernel_end = .;
    }

    /* 内核实际占用的物理内存范围（物理页帧分配器据此保留） */
    kernel_phys_end = . - KERNEL_VIRT_BASE;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note*)
        *(.comment*)
    }
}
