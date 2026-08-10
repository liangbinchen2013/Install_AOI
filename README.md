**脚本编写在windows系统上，请在运行前输入命令：**```sed -i 's/\r$//' 脚本名.sh```**修改格式！**

**本脚本支持x86_64与aarch64架构。对于aarch64架构，脚本会自动用官方 npm 包 `@aoi-js/server` 本地构建等价镜像（`aoi-js/server:arm64`，与官方镜像内容一致）**

## 运行顺序

setup_aoi.sh -> setup_azukiiro.sh -> setup_OSS.sh/setup.judge.sh

**注意每个脚本务必需要sudo运行。**

> 脚本采用评测后端为 main_judger_wrapper.py，请把该python文件放置在与所有sh文件同目录。

## 各个sh脚本作用

### setup_aoi.sh

安装AOI本体，脚本会预先检查系统环境是否达标。

需要的前置软件：

| 软件类别 | 软件 | 
| ---- | ---- | 
| 基础系统工具 | curl |
|  | tar | 
|  | openssl |
|  | base64（coreutils） | 
| 容器运行环境 | Docker | 
|  | Docker Compose v2 | 
| 网络查看工具 | ss / netstat | 
| 磁盘内存工具 | df | 
|  | /proc/meminfo |
| 系统包管理器 | apt / dnf / yum / zypper |

## setup_azukiiro.sh

安装AOI官方后端，

## setup_OSS.sh

安装AOI要求的存储器，OSS。

## setup_judge.sh

安装评测机，评测机为 main_judger_wrapper.py 。

**本项目文档后缀The-AOI-Project的，原创为AOI官方。本项目仅作修改。**
