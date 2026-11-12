# DeepSeek Harness 崩溃修复工具

用于修复 Windows 版 DeepSeek Harness 因运行时依赖不一致或沙盒目录权限异常而无法启动的问题。

## 使用

1. 关闭正在运行的 DeepSeek Harness。
2. 双击 `Repair-DeepSeekHarness.cmd`。
3. 修复完成后脚本会尝试重新启动程序。

只检查问题、不修改任何内容：

```powershell
.\Repair-DeepSeekHarness.cmd -DryRun
```

如果程序不在默认位置，可以手动指定安装目录：

```powershell
.\Repair-DeepSeekHarness.ps1 -InstallDir "D:\deepseek harness"
```

## 修复内容

- 检查并隔离与当前版本不一致的运行时依赖。
- 停用引用冲突运行时的旧扩展。
- 修正 DeepSeek Harness 安装目录的 Windows 沙盒读取权限。
- 修复前创建带时间戳的备份。
- 重复运行时会跳过已经完成的项目。

## 系统要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或 PowerShell 7

脚本只针对本机安装的 DeepSeek Harness 做修复，不上传任何数据。
