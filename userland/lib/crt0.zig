//! 用户程序启动代码（crt0）
//!
//! 内核 execve 后的进程入口：RSP 指向 [argc][argv...][NULL]。
//! 按 SysV 惯例向 main 传 (argc, argv, envp)——
//!   - C 程序：int main(int argc, char **argv, char **envp)
//!   - Zig 程序：export fn main() i32（多余实参被自然忽略）
//! main 返回后调用 libc 的 exit()（先跑 atexit 处理器再陷入内核）。
//!
//! 同时拉入 libc.zig：Zig 程序也因此获得完整 C 符号（两种语言互调）。

comptime {
    _ = @import("libc.zig");
}

export var __argc: i64 = 0;
export var __argv: [*]const ?[*:0]const u8 = undefined;

extern fn main() i32;
extern fn exit(code: c_int) noreturn;
extern var environ: [*:null]const ?[*:0]const u8;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq (%rsp), %rdi          # argc
        \\leaq 8(%rsp), %rsi         # argv[]
        \\leaq environ(%rip), %rdx   # envp（OusiaOS 恒为空表）
        \\movq %rdi, __argc(%rip)
        \\movq %rsi, __argv(%rip)
        \\andq $-16, %rsp            # SysV: 入口处 16 字节对齐
        \\callq main
        \\movl %eax, %edi            # exit(main 返回值)
        \\callq exit
        \\1: hlt
        \\jmp 1b
    );
}
