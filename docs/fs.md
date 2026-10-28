# 文件系统：ATA 块设备 + ext2 根文件系统（读/写）

本文讲 ZOS 怎么从"一块真磁盘"到"/bin、/etc 全在盘上，写进去的
文件重启还在"。三层自底向上：

```
vfs.zig     名字空间：路径解析 + 挂载表 + 权限     （ext2 = 根）
ext2.zig    磁盘格式：超级块/位图/inode/目录项     （读 + 写）
ata.zig     块设备：512B 扇区读写（PIO 轮询）      （主通道主盘）
```

0.3 起 ext2 **整体作为根文件系统**（`vfs.mountExt2("/")`）：
`/bin`（用户程序，execve 直接从 ext2 inode 加载）、`/etc`（系统
配置）全在盘上，initrd/tarfs 不再参与引导（grub.cfg 已无 module2；
tarfs 代码保留作教学对照与无盘兜底）。ext2 是**工业格式**——镜像
文件可以用宿主机的 `mke2fs`/`debugfs`/`e2fsck` 互相操作，数据真正
落盘、掉电不丢。

## 1. ata.zig —— 块设备层

磁盘与串口/键盘（字符流）的本质区别：以 512 字节扇区为单位、
可随机寻址。ATA PIO 协议全部走 I/O 端口：

| 端口 | 寄存器 | 作用 |
|---|---|---|
| 0x1F0 | DATA | 16 位批量数据（insw/outsw） |
| 0x1F2..0x1F5 | 扇区数 + LBA 低 24 位 | 寻址 |
| 0x1F6 | DRIVE | 0xE0 \| LBA[27:24]（LBA28 模式，bit4 选主/从盘） |
| 0x1F7 | STATUS/CMD | 读=状态，写=命令 |
| 0x3F6 | 控制/备用状态 | ioWait 的 400ns 延时原语 |

一次读扇区的完整握手（`readSectors`）：

1. 等 BSY 清零（设备空闲）；
2. 写 LBA 地址 + 扇区数到 0x1F2..0x1F6；
3. 写命令 0x20（READ PIO）到 0x1F7；
4. 等 DRQ 置位（数据就绪）→ `insw` 搬 256 字；每个扇区重复 4。

写同理（0x30），收尾 `flush()` 发 FLUSH CACHE（0xE7）——按逻辑操作
刷一次而不是按块刷。探测用 IDENTIFY DEVICE（0xEC）：返回 512 字节
"身份证"（型号字符串在字 27-46、LBA28 总扇区数在字 60-61）；
无盘时 LBA_MID/HI 读回 0xFF，据此快速失败。

**并发约定**：驱动自身无锁。上层（ext2）把每个公开操作整体包进
cli/sti 临界区——磁盘 I/O 是"读-改-写"序列，中途被时钟中断抢占
会让另一个进程插入自己的 ATA 命令、污染块缓存。QEMU 下一次块操作
只有微秒级，关中断窗口可接受（见 ext2.zig 头注）。

## 2. ext2 磁盘布局

`mke2fs -b 1024` 的经典布局（build/disk.img，96MB = 12 个块组）：

```
块 0        引导区（未用）
块 1        超级块：固定在字节 1024 处，magic 0xEF53@+56
块 2        组描述符表（每组 32 字节）
块 3..      组0：块位图 | inode位图 | inode表 | 数据块...
            组1：同构（8192 块/组）
```

每个块组自带三件套——**两张位图**（块/inode 的空闲表，1KB 块的
位图恰好 8192 位）和 **inode 表**（128B/inode，1KB 块装 8 个，
不跨块——挂载时校验 `block_size % inode_size == 0`）。

内核只解析用得到的超级块字段（偏移自字节 1024 起）：

| 偏移 | 字段 | 用途 |
|---|---|---|
| 0/4 | inodes_count/blocks_count | 节点编码上限 / 越界保护 |
| 12/16 | free_blocks/inodes_count | 分配时回写（e2fsck 对账） |
| 24 | log_block_size | block_size = 1024 << log（支持 1K/2K/4K） |
| 32/40 | blocks/inodes_per_group | 组内取模定位 |
| 56 | magic | 0xEF53 |
| 76/84/88 | rev_level/first_ino/inode_size | rev1 动态字段 |
| 96 | feature_incompat | 只接受 FILETYPE(0x2)，其余拒绝挂载 |

组描述符（32B/组）：块位图块号、inode 位图块号、inode 表块号、
空闲块/inode 计数、目录计数——alloc/free 时计数同步回写，
`e2fsck -fn` 才能对上账。

## 3. inode 与块映射

inode 是文件的元数据 + 块号数组（`i_block[15]`）：

```
[0..11]  直接块            12 KB
[12]     一重间接          12KB + 256KB   （间接块 = 块号数组，1KB 块装 256 个）
[13]     二重间接          + 64MB
[14]     三重间接          + 16GB
```

`mapFileBlock(ib, bi, alloc)`：把逻辑块号 bi 解析成物理块号。
`alloc=true` 时沿路缺失的间接块/数据块都会分配并**清零落盘**
（`allocZeroBlock`），并累计进 `i_blocks`（512 字节扇区数，
含间接块——这是 e2fsck 的另一个对账项）。

定位 inode：`组 = (ino-1) / inodes_per_group`，
`表内偏移 = (ino-1) % inodes_per_group × inode_size`。
`writeInode` 按字段回写（mode/uid/gid/size/links/i_blocks/dtime），
不碰 atime/ctime 等未管理字段——读出块、补丁、刷盘。

## 4. 空闲管理：位图分配

`balloc`/`ialloc` = 在组位图里找第一个 0 位并置 1。一次分配要
同步四处状态（**一致性义务清单**，漏一处 e2fsck 就报警）：

1. 位图本身（置位 + 刷盘）；
2. 组描述符的 free 计数（RAM 镜像改完整块回写）；
3. 超级块的 free 计数（扇区 2..4 整体回写）；
4. 分配给文件的块还要累加 inode 的 i_blocks。

释放（`bfree`/`ifree`）对称回退，带双重释放防御（位图已是 0 就忽略）。
删除文件时释放数据块 + 各级间接块（`freeTree` 递归），并把
`i_dtime` 写成当前墙钟（CMOS RTC → unix 秒，`days_from_civil`
算法算日期）——e2fsck 要求删除的 inode 有非零 dtime。

## 5. 目录：一串变长记录

目录就是普通文件，内容是连续的目录项：

```
┌────────┬─────────┬──────────┬───────────┬─────────┐
│ ino 4B │ rec_len │ name_len │ file_type │ name[]  │
└────────┴─────────┴──────────┴───────────┴─────────┘
```

rec_len 是"到下一条目"的跨度——这正是删除算法的关键：

- **查找**（`dirLookup`）：扫条目，名字逐字节比较；
- **插入**（`dirAdd`）：先找 `ino==0` 的空洞复用；再找现条目的
  松弛空间（rec_len ≥ 自身最小长度 + 新条目所需）——收缩前者、
  紧随其后插入新条目；都没有就在目录尾部追加一块；
- **删除**（`dirRemove`）：把被删条目的 rec_len **并入前一条目**
  （块首则就地置成空洞）——后续条目全部保持原位不动。

`rmdir` 先 `dirIsEmpty`（只允许剩 "." ".."），再走与 unlink 相同的
释放路径，并把父目录 links_count 减一（目录 links = 2 + 子目录数，
mkdir 时对偶地加一）。

## 6. 一次写操作的全链路

`echo hi > /a.txt`（shell 重定向 → 子进程 open+dup2 → exec echo
→ write(1)）：

```
sysOpen("/a.txt", O_WRONLY|O_CREAT|O_TRUNC)
  └─ vfs.resolveCred        挂载点前缀匹配 → ext2.lookupPath 失败
       └─ vfs.createFile    挂载点之下 → ext2 分支：
            ialloc()         inode 位图找 0 位 → 清零 inode
            dirAdd(父,"a.txt",ino,FT_REG)
                             父目录加条目（无空位则扩一块）
  └─ O_TRUNC → ext2.truncate  释放旧块、size=0（覆盖写场景）
sysWrite(fd, "hi\n")
  └─ vfs.write(node=1024+ino) → ext2.writeFile(ino, 0, "hi\n")
       mapFileBlock(bi=0, alloc=true)   balloc 数据块
       blockPtr + memcpy + flushBlock   经缓存写盘
       writeInode(size=3, i_blocks+=2)
ata.writeSectors(...)  PIO outsw 落盘 → flush()
```

读对称：`vfs.read` → `ext2.readFile` → 逐块映射 + memcpy。

## 7. 块缓存与并发

`ext2.zig` 自带一个 **24 块直接映射缓存**（`blockPtr`：`b % 24`
选槽，未命中读盘装入；写穿透：改完立即 `flushBlock`，无脏页）。
由此产生一条**切片借用纪律**：任何分配/递归都可能换出当前槽，
所以**禁止跨 blockPtr 持有切片**——写回前必须重新取块。
（`mapIndirect` 的 `allocZeroBlock` 之后重新 `blockPtr(root)`
就是在兑现这条纪律。）

并发模型：单核 + 每个公开操作整体 cli/sti（见 §1）。
代价是时钟中断最多被推迟一次大文件写的时长（QEMU 下毫秒级），
教学上换来"不需要锁"的心智模型。

## 8. VFS：根挂载与节点编号

vfs 节点编号：

| 节点 | 含义 |
|---|---|
| 0 / 1 | `/`（虚拟根；ext2 根挂载时信息/列表透传 ext2）/ `/dev/console` |
| 2..N+1 | tarfs 节点（仅无盘兜底模式） |
| 1024+ino | ext2 节点（ino = ext2 inode 号） |

`mountExt2("/")` 进入**根挂载**模式：`mountMatch` 对任何路径都
命中（整个名字树归 ext2），`resolve("/bin/sh")` → `ext2.lookupPath
("bin/sh")`。根目录节点仍是 ROOT_NODE(0)，`info/listDir` 透传给
ext2 的根 inode。无盘时回退 tarfs（老的双文件系统形态
`mountExt2("/mnt")` 也保留：前缀匹配挂载点，嫁接到名字树）。

execve 从 ext2 读 ELF：整文件读入 8MB 暂存缓冲（`proc.zig` 的
`exec_disk_buf`；ReleaseSafe 用户程序 2-4MB，超限先查大小直接
拒绝）再走 elf.load——tarfs 是零拷贝切片，ext2 是块设备读入，
差异被 vfs.read 吸收。稀疏文件（ELF 段间隙产生的洞）按 ext2
语义读作零。

## 9. 制作与检查磁盘镜像

```bash
zig build iso                      # mkiso.sh 调 mkdisk.sh：96MB ext2 根
                                   # （/bin 用户程序 + /etc + diskroot 注释；
                                   #  已存在则跳过——改过程序后 --force 重建）
./scripts/mkdisk.sh --force        # 重建并清空

# 宿主机直接操作镜像（ext2 的好处：标准工具都能读）
debugfs -R "ls -l /" build/disk.img
debugfs -R "cat /etc/motd" build/disk.img
e2fsck -fn build/disk.img          # 一致性体检（位图/计数/目录项链）

# 自动化：QEMU 里写 → 宿主机 e2fsck + debugfs 逐字节核对
python3 scripts/fscheck.py
```

测试脚本：`scripts/test.py`（shell 全回归，含根目录读写删）；
`scripts/fscheck.py`（写后落盘校验：重定向+追加、20KB 跨间接块
下载逐字节比对、chmod 落盘、目录建删、e2fsck 全绿）。
持久性演示：`echo hi > /hi.txt` → Ctrl-A X 退出 → 重新
`zig build run` → `cat /hi.txt` 还在。

## 10. 已知取舍（= 练习清单）

- 无日志：崩溃一致性只保证"单操作内同步写"；加一层日志（journal）
  是经典练习（ext3 就是这么来的）；
- 单文件系统实例：多盘/多挂载点挂载表是一小步重构；
- 目录无哈希索引（dir_index 特性被忽略，线性扫描）、无 inode 缓存；
- 不设 atime/mtime（dtime 有墙钟，`nowSecs()` 可以直接复用）；
- 稀疏文件：写到哪里分配到哪里，但不产生"洞"（读未写区域会先分配清零）；
- 并发：cli 全程粗粒度，改异步 I/O + 等待队列是进阶练习。
