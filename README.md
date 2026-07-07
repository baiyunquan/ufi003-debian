# ufi003-debian
适用于UFI003_MB_V02的Debian构建脚本

## 特性
- NFS client v2/v3/v4, NFS server v3/v4
- KSMBD
- 默认300% zram
- boot-no-modem-oc.img内核超频至1.2GHz

## 手动更换内核
```shell
cd /tmp
wget KERN_DEB_URL
wget BOOT_IMG_URL
apt purge linux-image*
apt install ./linux-image*.deb
dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot bs=1M
reboot
```

## 本地构建
1. 克隆本仓库
2. 安装软件包 `debootstrap rsync qemu-user-static binfmt-support android-sdk-libsparse-utils`
3. 进入rootfs目录，以root权限运行`build.sh`
4. 构建完成后会在rootfs目录得到rootfs.img，kernel目录得到boot.img

## EDL 打包与刷写经验

这次在 `UFI003_MB_V02` 上跑通之后，最重要的经验不是某个单独镜像，而是下面这两点:

1. 不要假设目标设备还保留着原始分区表。之前反复试刷后，设备上的 GPT 很可能已经和项目默认假设不一致。
2. `boot.img` 大于 16 MiB 的时候，不适合直接写入 `boot` 分区；更稳妥的方案是让 `lk1st` 从 `system` 分区里的 `bootfs` 启动，再把 Debian rootfs 放进 `userdata`。

因此现在推荐的 `ufi003-debian` 刷写路径是:

1. 构建或下载 `rootfs.img.xz`
2. 准备 `boot.img`
3. 准备 `emmc_appsboot-test-signed.mbn`
4. 用 `scripts/make-edl-package.sh` 生成完整 EDL 包
5. 在 EDL 模式下用包内的 `flash-ufi003-edl.sh` 刷写

生成 EDL 包时，脚本现在会额外生成一套已知可用的 UFI003 GPT:

* `gpt_both0.bin`
* `gpt_main0.bin`
* `gpt_backup0.bin`
* `gpt.env`

这套 GPT 保持 `modem`、`fsc`、`fsg`、`persist`、`sec` 等前段布局不变，同时明确约束:

* `boot` 分区保持 16 MiB，仅用于占位
* `system` 分区用于存放 `bootfs`
* `userdata` 分区用于存放 Debian rootfs

这样做的意义是，哪怕目标机器之前被别的方案改乱过 GPT，只要还能进 EDL，这个包就能先恢复到 `ufi003-debian` 预期的分区布局，再继续刷系统。

## 重新打包 EDL 产物

如果你已经有以下文件:

* `rootfs.img.xz`
* `boot.img`
* `emmc_appsboot-test-signed.mbn`

可以直接在仓库根目录执行:

```sh
ROOTFS_XZ_PATH=/path/to/rootfs.img.xz \
BOOT_IMG_PATH=/path/to/boot.img \
ABOOT_MBN_PATH=/path/to/emmc_appsboot-test-signed.mbn \
bash scripts/make-edl-package.sh output
```

生成的 `output/` 目录会包含:

* 可直接用于 `edl qfil` 的 `rawprogram0.xml` 和 `patch0.xml`
* 自带 GPT 的刷写包
* `flash-ufi003-edl.sh`
* `custom-boot.img`，仅用于 fastboot 临时启动测试

## GitHub Actions

仓库中的 workflow 现在适合两类用途:

* `build.yml`: 从源码构建 rootfs / aboot，并产出 release 文件
* `build-edl-flash.yml`: 重新打包为带 GPT 的 EDL 刷机包

如果后续要再次构建，建议优先走 workflow 产出完整 EDL 包，而不是只拿单独的 `rootfs.img.xz` 或 `boot.img` 手工拼装。
