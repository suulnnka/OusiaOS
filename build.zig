//! ZOS 构建脚本
//!
//! 常用命令：
//!   zig build          编译内核 → zig-out/bin/zos-kernel.elf
//!   zig build iso      编译内核并制作 GRUB 启动 ISO → build/zos.iso
//!   zig build run      构建 ISO 并启动 QEMU（串口接到当前终端）
//!
//! 教学要点：内核是 freestanding 目标（无标准库运行时依赖），
//! 需要内核代码模型(-mcmodel=kernel)、关闭 red-zone（中断会破坏它）。

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    // ---------------- 内核 ----------------
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel, // 高端地址寻址
        .red_zone = false, // 内核不能用 red-zone（中断帧会覆盖）
        .single_threaded = true,
        .stack_protector = false,
    });

    const kernel = b.addExecutable(.{
        .name = "zos-kernel.elf",
        .root_module = kernel_mod,
        .use_llvm = true, // 使用 LLVM 后端（自研后端不支持 port I/O 指令）
    });
    kernel.linker_script = b.path("kernel/linker.ld");
    kernel_mod.addAssemblyFile(b.path("kernel/boot.S")); // 32 位引导 + 长模式跳板

    const install_kernel = b.addInstallArtifact(kernel, .{});
    b.getInstallStep().dependOn(&install_kernel.step);

    // ---------------- 用户程序 ----------------
    // 静态 ELF（链接到 0x400000），打包进 initrd 的 /bin/。
    // 用户态中断会切到内核栈，理论上可用 red-zone；
    // 这里同样关闭，保持简单。
    const user_progs = [_][]const u8{
        "sh",   "ls",   "cat",  "echo", "ps",
        "uname", "sleep", "hello", "forkdemo",
        "ping", "ifconfig",
    };
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    inline for (user_progs) |prog| {
        const exe = b.addExecutable(.{
            .name = prog,
            .root_module = b.createModule(.{
                .root_source_file = b.path("userland/" ++ prog ++ ".zig"),
                .target = user_target,
                .optimize = .ReleaseSafe,
                .red_zone = false,
                .stack_protector = false,
                .single_threaded = true,
            }),
            .use_llvm = true,
        });
        exe.linker_script = b.path("userland/user.ld");
        const install = b.addInstallArtifact(exe, .{ .dest_sub_path = "user/" ++ prog });
        b.getInstallStep().dependOn(&install.step);
    }

    // ---------------- C 程序支持：libzos.a（libc.zig + clib.c + crt0）----------------
    // 用 zig cc 把 C 程序链到这个静态库，即可移植标准 C 代码。
    const libc_mod = b.createModule(.{
        .root_source_file = b.path("userland/lib/libc.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .red_zone = false,
        .stack_protector = false,
        .single_threaded = true,
    });
    libc_mod.addCSourceFile(.{
        .file = b.path("userland/lib/clib.c"),
        .flags = &.{ "-std=c11", "-fno-stack-protector" },
    });
    libc_mod.addIncludePath(b.path("userland/include"));

    const libc_lib = b.addLibrary(.{
        .name = "zos",
        .root_module = libc_mod,
        .linkage = .static,
    });
    const install_libc = b.addInstallArtifact(libc_lib, .{});
    b.getInstallStep().dependOn(&install_libc.step);

    // ---------------- C 程序（zig cc + libzos.a）----------------
    const c_progs = [_][]const u8{ "cdemo", "wc", "curl" };
    inline for (c_progs) |prog| {
        const cc = b.addSystemCommand(&.{
            b.graph.zig_exe, "cc",
            "-target",       "x86_64-freestanding",
            "-O1",
            "-nostdlib",
            "-no-pie",
            "-fno-stack-protector",
            "-Iuserland/include",
            "-Wl,--script=userland/user.ld",
            "-Wl,-e,_start",
            "-o",
        });
        const out = cc.addOutputFileArg(prog);
        cc.addFileInput(b.path("userland/" ++ prog ++ ".c"));
        cc.addArg("userland/" ++ prog ++ ".c");
        cc.addArg("zig-out/lib/libzos.a");
        cc.step.dependOn(&install_libc.step);
        const install = b.addInstallFile(out, "bin/user/" ++ prog);
        install.step.dependOn(&cc.step);
        b.getInstallStep().dependOn(&install.step);
    }

    // ---------------- ISO（GRUB 引导镜像）----------------
    const iso_step = b.step("iso", "Build bootable GRUB ISO (build/zos.iso)");
    const mkiso = b.addSystemCommand(&.{"./scripts/mkiso.sh"});
    mkiso.step.dependOn(b.getInstallStep());
    iso_step.dependOn(&mkiso.step);

    // ---------------- QEMU 运行 ----------------
    const run_step = b.step("run", "Build ISO and boot in QEMU");
    const run_cmd = b.addSystemCommand(&.{"./scripts/run.sh"});
    run_cmd.step.dependOn(iso_step);
    run_step.dependOn(&run_cmd.step);

    // ---------------- 自动化测试（PTY 驱动串口 shell）----------------
    const test_step = b.step("test-run", "Boot in QEMU and run scripted shell commands");
    const test_cmd = b.addSystemCommand(&.{ "python3", "scripts/test.py" });
    test_cmd.step.dependOn(iso_step);
    test_step.dependOn(&test_cmd.step);
}
