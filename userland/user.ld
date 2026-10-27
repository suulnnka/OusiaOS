/* ZOS 用户程序链接脚本：静态 ELF，加载基址 0x400000 */
ENTRY(_start)

SECTIONS
{
    . = 0x400000;

    .text   : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data   : { *(.data .data.*) }
    .bss    : { *(.bss .bss.*) *(COMMON) }

    /DISCARD/ : { *(.eh_frame*) *(.note*) }
}
