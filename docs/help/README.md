# LipidFlow Desktop help

LipidFlow Desktop is a standalone macOS and Windows application based on TidyMass Desktop 0.1.65. It has one workflow and one analysis tool. All computation runs locally in the bundled R environment.

- [Workflow](workflow.md): import, peak picking, annotation, quantification and export
- [Internal standard exploration](peak-extraction.md): QC chromatograms, candidate adducts and internal standards
- [Projects and troubleshooting](projects.md): saved results, reproducibility and environment checks

## Quick start

On macOS, open `LipidFlow.app`. On Windows, install the Windows x64 setup executable and open **LipidFlow** from the Start menu. From **Workflow**, choose **Untargeted lipidomics** to create a workflow project or open **Analysis tools** and choose **Internal standard exploration** to create a tool project. Choose a parent directory; a new project folder is created without replacing an existing folder.

For a complete study, prepare mzML/mzXML files, MS2 files for annotation, an internal-standard concentration workbook and polarity-specific Y_IS_opt tables from Internal standard exploration.

## 中文快速入门

本软件是独立的 LipidFlow macOS / Windows 桌面应用，沿用 TidyMass 的界面和本地分析架构。首页只有一个 Untargeted lipidomics workflow 和一个 Internal standard exploration 工具。

1. 在首页创建项目，选择本地保存位置。
2. 主流程依次为：数据导入、峰提取、脂质注释、绝对定量、结果导出。
3. 内标参考由 Internal standard exploration 生成。请分别保存 POS 和 NEG 的 Y_IS_opt CSV，在定量步骤选择相应文件。
4. 数据表只是预览，完整 CSV、R 对象、图形和日志在每次运行的文件夹中。

绝对定量沿用当前 lipidflowshiny 的方法：同一离子模式下，将 QC 中测得的内标峰面积用于各个样本。这不是逐样本测量内标的方法。所有浓度结果依赖输入的内标浓度和匹配关系。

## Keyboard shortcuts

On macOS, use **⌘W** to close the window and **⌘Q** to quit LipidFlow. On Windows, use **Ctrl+W** to close the window and **Ctrl+Q** to quit. With this single-window app, closing the last window exits the app. If an analysis is running, the existing confirmation dialog lets you keep it running or stop and quit. Standard Edit, View and Window shortcuts are listed in the application menus.
