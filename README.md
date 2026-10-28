# raycast-toolbox

我自己用的 Raycast 相关的一切：Script Commands、它们依赖的小工具，以后也可能有扩展和配置。

## 用法

把这个仓库的根目录加到 Raycast 的 Script Commands 目录里（Raycast 设置 → Extensions → Script Commands → Add Directories）。根目录下的 `*.sh` 就是脚本命令；需要编译的工具各占一个子目录，先运行里面的 `build.sh`。

## 目录

| 命令 | 说明 |
|---|---|
| [打开密码菜单](open-passwords-menu.sh) | 打开 macOS「密码」的菜单栏窗口，并给它加上键盘操作。见 [passwords-menu](passwords-menu/README.md) |
