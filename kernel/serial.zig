//! 串口（UART 16550）驱动 —— COM1
//!
//! 教学要点：x86 的 I/O 端口空间访问（in/out 指令）、设备轮询。
//! QEMU 的 `-serial stdio` 把 COM1 接到宿主终端，因此串口同时是
//! 内核日志输出和无头(headless)测试的主要通道。

const PORT = 0x3F8; // COM1 基地址

// 寄存器偏移（相对 PORT）
const REG_DATA: u16 = 0; // 读=接收字节 / 写=发送字节
const REG_IER: u16 = 1; // 中断使能
const REG_FCR: u16 = 2; // FIFO 控制
const REG_LCR: u16 = 3; // 线路控制（波特率/字长）
const REG_MCR: u16 = 4; // Modem 控制
const REG_LSR: u16 = 5; // 线路状态（收/发就绪位）

/// 初始化：115200 波特、8N1、开 FIFO
pub fn init() void {
    outb(PORT + REG_IER, 0x00); // 关中断（中断模式下再打开）
    outb(PORT + REG_LCR, 0x80); // DLAB=1，准备写波特率除数
    outb(PORT + 0, 0x01); // 除数低字节 = 1 (115200)
    outb(PORT + 1, 0x00); // 除数高字节
    outb(PORT + REG_LCR, 0x03); // DLAB=0, 8 数据位, 无校验, 1 停止位
    // 0xC1 = 使能 FIFO + 触发阈值 1 字节 + 不清空已有数据
    // （清空位会丢弃启动早期到达的字节；触发 1 字节保证即时中断）
    outb(PORT + REG_FCR, 0xC1);
    outb(PORT + REG_MCR, 0x0B); // DTR+RTS+OUT2
}

/// 阻塞写一个字节（查询发送保持寄存器空）
pub fn writeByte(c: u8) void {
    while (inb(PORT + REG_LSR) & 0x20 == 0) {} // 等待 THR 空
    outb(PORT + REG_DATA, c);
}

/// 非阻塞读：有数据返回字节，否则返回 null
pub fn readByte() ?u8 {
    if (inb(PORT + REG_LSR) & 0x01 != 0) return inb(PORT + REG_DATA);
    return null;
}

// ---- 端口 I/O 原语（内联汇编）----
pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (val),
          [p] "{dx}" (port),
    );
}

pub inline fn outw(port: u16, val: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (val),
          [p] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

/// 停顿一小段（等慢速设备），向端口 0x80 写入无效字节
pub inline fn ioWait() void {
    outb(0x80, 0);
}
