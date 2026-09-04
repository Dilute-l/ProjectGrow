Git 速查表（ProjectGrow 开发用）

## 命令在哪里输入？
1. 打开文件夹：`C:\Users\catkin\Documents\test-2\ProjectGrow`
2. 在文件夹**空白处点右键**：
   - Windows 11：选「在终端中打开」
   - Windows 10：按住 Shift 再右键 →「在此处打开 PowerShell 窗口」
3. 在弹出的黑色/深色窗口里输入命令，**每行输入完按回车**

## 每次开工（必做）
```
git status    ← 查看当前状态：改了哪些文件、在哪个分支
git pull      ← 拉取远端最新代码
```

## 完成一个小功能后（提交到本地）
```
git status               ← 先看改了哪些文件
git add .                ← 把所有改动加入"待提交"
git commit -m "说明"      ← 提交（把"说明"换成你的话，例如"添加攻击功能"）
```

## 收工（上传到 GitHub）
```
git pull                 ← 推送前先拉一次（防止远端有新提交）
git push                 ← 推送到 GitHub
```

## 出错时的排查
- 提示 `not a git repository` → 你没在 ProjectGrow 文件夹里，先 cd 到该目录
- pull 被拒绝 → 本地有未提交改动，先 `git add .` + `git commit`，再 pull
- 看到 `CONFLICT` / `<<<<<<<` → 和别人改了同一处，冲突了，找 AI 帮忙解决
- push 被拒绝 → 先 `git pull`，再 `git push`

## 注意事项
- 一次只输入一行，输完按回车，命令才会执行
- 输入时**关闭中文输入法**（全角符号、中文括号会让命令报错）
- 拿不准时随时问 AI，或者直接让 AI 帮你执行命令
