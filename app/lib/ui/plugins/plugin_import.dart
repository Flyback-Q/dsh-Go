// 插件导入：市场之外的三个来源——npm spec / Git / tarball URL（在线导入），
// 本地 .tgz 与 .dshgo 分享码文件（文件导入）。
//
// 在线导入先走 `pluginManager/inspect`，把真实包名、版本、描述读出来再装；
// 文件导入的 .dshgo 交给现有的分享码导入链（`showShareImportSheet`），
// 本地 tarball 写成临时文件后用 `file:` spec 交给宿主。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../share_code/share_codec.dart';
import '../../share_code/share_models.dart';
import '../../state/plugins_state.dart';
import '../common/app_sheet.dart';
import '../share_code/import_sheet.dart' show ShareOrigin, showShareImportSheet;
import '../theme/theme.dart';
import 'plugin_actions.dart';
import 'plugin_widgets.dart';

/// 导入入口交给外层执行的东西：要么直接安装，要么交给分享码导入链。
sealed class PluginImportOutcome {
  const PluginImportOutcome();
}

final class PluginImportInstall extends PluginImportOutcome {
  const PluginImportInstall(this.request);
  final PluginInstallRequest request;
}

final class PluginImportShare extends PluginImportOutcome {
  const PluginImportShare(this.payload, {this.fileName});
  final SharePayload payload;
  final String? fileName;
}

/// 输入被归类成什么，用来给一行提示。
enum PluginImportKind {
  npm('npm 包名，例如 dsh-plugin-x@1.2.3'),
  tarball('远程 tarball 地址，会直接下载安装'),
  git('Git 仓库，按默认分支的最新提交安装'),
  gitPinned('Git 仓库（已锁定提交）'),
  local('本地路径（仅本机宿主可用）'),
  shareCode('分享码文本，走分享码导入');

  const PluginImportKind(this.hint);
  final String hint;
}

class PluginImportInput {
  const PluginImportInput({required this.spec, required this.kind});

  /// 交给 `pluginManager/installBundle` 的 spec。
  final String spec;
  final PluginImportKind kind;

  bool get needsLocalHost => kind == PluginImportKind.local;
}

final _npmPrefix = RegExp(r'^(?:npm|pnpm)\s+(?:i|install|add)\s+', caseSensitive: false);
final _globalFlag = RegExp(r'^(?:-g|--global)\s+');
final _dshPrefix = RegExp(r'^dsh\s+plugin\s+(?:--profile\s+\S+\s+)?add\s+');
final _scpLike = RegExp(r'^[\w.-]+@[\w.-]+:');

/// 把用户贴进来的东西收敛成一个 spec。容忍整条安装命令被粘进来。
PluginImportInput? normalizePluginImportInput(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  for (final re in [_dshPrefix, _npmPrefix, _globalFlag]) {
    s = s.replaceFirst(re, '').trim();
    if (s.isEmpty) return null;
  }

  // Git 简写：github.com/a/b、https://github.com/a/b、git@github.com:a/b
  final githubShorthand = RegExp(r'^(?:https?://)?(?:www\.)?github\.com/([\w.-]+)/([\w.-]+)/?$');
  if (githubShorthand.firstMatch(s) case final m?) {
    final repo = m.group(2)!.replaceAll(RegExp(r'\.git$'), '');
    return PluginImportInput(
      spec: 'git+https://github.com/${m.group(1)}/$repo.git',
      kind: PluginImportKind.git,
    );
  }
  if (_scpLike.hasMatch(s)) {
    return PluginImportInput(spec: s, kind: PluginImportKind.git);
  }
  if (s.startsWith('git+') || s.startsWith('git://') || s.startsWith('github:')) {
    return PluginImportInput(spec: s, kind: PluginImportKind.git);
  }
  if (s.startsWith('http://') || s.startsWith('https://')) {
    final path = Uri.tryParse(s)?.path.toLowerCase() ?? '';
    if (path.endsWith('.tgz') || path.endsWith('.tar.gz') || path.endsWith('.tar')) {
      return PluginImportInput(spec: s, kind: PluginImportKind.tarball);
    }
    // 带 .git 后缀的 http(s) 地址当 Git 仓库
    if (path.endsWith('.git') || s.contains('github.com/')) {
      final pinned = s.contains('#');
      return PluginImportInput(
        spec: pinned ? s : (s.endsWith('.git') ? s : 'git+$s.git'),
        kind: pinned ? PluginImportKind.gitPinned : PluginImportKind.git,
      );
    }
    // 其余 http 地址：可能是分享码原文
    return PluginImportInput(spec: s, kind: PluginImportKind.tarball);
  }
  if (s.startsWith('file:') || s.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(s)) {
    return PluginImportInput(
      spec: s.startsWith('file:') ? s : 'file:$s',
      kind: PluginImportKind.local,
    );
  }
  return PluginImportInput(spec: s, kind: PluginImportKind.npm);
}

/// 打开导入面板。安装在这里执行，这样面板关掉之后提示仍然落在页面上。
Future<void> showPluginImportSheet(BuildContext context) async {
  final outcome = await showAppSheet<PluginImportOutcome>(
    context,
    isScrollControlled: true,
    heightFactor: 0.9,
    builder: (_) => const PluginImportSheet(),
  );
  if (outcome == null || !context.mounted) return;
  switch (outcome) {
    case PluginImportInstall(:final request):
      await runPluginInstall(context, request);
    case PluginImportShare(:final payload):
      await showShareImportSheet(context, payload, origin: ShareOrigin.file);
  }
}

class PluginImportSheet extends ConsumerStatefulWidget {
  const PluginImportSheet({super.key});

  @override
  ConsumerState<PluginImportSheet> createState() => _PluginImportSheetState();
}

class _PluginImportSheetState extends ConsumerState<PluginImportSheet> {
  final _input = TextEditingController();
  PluginImportInput? _parsed;
  PluginInspection? _inspection;
  String? _error;
  bool _checking = false;
  bool _picking = false;

  /// 文件导入的 tarball 上限：分享码有自己的上限，这里只拦明显不合理的包。
  static const _maxFileBytes = 64 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _input.addListener(_reparse);
  }

  @override
  void dispose() {
    _input.removeListener(_reparse);
    _input.dispose();
    super.dispose();
  }

  void _reparse() {
    final parsed = normalizePluginImportInput(_input.text);
    if (parsed?.spec == _parsed?.spec) return;
    setState(() {
      _parsed = parsed;
      _inspection = null;
      _error = null;
    });
  }

  PluginHost? get _host => ref.read(pluginHostProvider);

  String? _blockedReason(PluginImportInput input) {
    final host = _host;
    if (host == null) return '还没有连上宿主，先选一台。';
    if (!host.canInstall) return '这台主机不能从这里安装插件。';
    if (input.needsLocalHost && !host.isLocal) return '本地文件只能装到本机；远程宿主请用在线导入。';
    return null;
  }

  Future<void> _check() async {
    final input = _parsed;
    if (input == null || _checking) return;
    final blocked = _blockedReason(input);
    if (blocked != null) {
      setState(() => _error = blocked);
      return;
    }
    final client = _host!.client;
    setState(() {
      _checking = true;
      _error = null;
      _inspection = null;
    });
    try {
      final inspection = await client.inspectPlugin(input.spec);
      if (!mounted) return;
      setState(() => _inspection = inspection);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = describePluginError(error).message);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _install() {
    final input = _parsed;
    final inspection = _inspection;
    if (input == null || inspection is! PluginInspectionAccepted) return;
    final name = inspection.name;
    if (name == null || name.isEmpty) {
      setState(() => _error = '宿主没有报出包名，无法安装。');
      return;
    }
    final request = PluginInstallRequest(
      name: name,
      spec: input.spec,
      title: name,
      registry: inspection.registry,
    );
    Navigator.pop(context, PluginImportInstall(request));
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final outcome = await _readPickedFile();
      if (!mounted || outcome == null) return;
      Navigator.pop(context, outcome);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = switch (error) {
        FormatException(:final message) => '$message',
        FileSystemException() => '读不了这个文件。',
        _ => '$error',
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 按魔数判断，不依赖扩展名：gzip 是 tarball，`{` 是分享码 JSON。
  Future<PluginImportOutcome?> _readPickedFile() async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in picked.readAsByteStream()) {
      bytes.add(chunk);
      if (bytes.length > _maxFileBytes) throw const FormatException('文件超过 64 MB，换个更小的包。');
    }
    final data = bytes.takeBytes();
    if (data.isEmpty) throw const FormatException('这个文件是空的。');

    if (data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
      final host = _host;
      if (host == null || !host.canInstall) throw const FormatException('这台主机不能从这里安装插件。');
      if (!host.isLocal) throw const FormatException('本地 tarball 只能装到本机；远程宿主请用在线导入。');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/dsh-plugin-import-${DateTime.now().millisecondsSinceEpoch}.tgz');
      await file.writeAsBytes(data, flush: true);
      final name = _nameFromPath(file.path);
      return PluginImportInstall(
        PluginInstallRequest(name: name, spec: 'file:${file.path}', title: name),
      );
    }

    final text = utf8.decode(data, allowMalformed: true);
    if (text.trimLeft().startsWith('{')) {
      return PluginImportShare(decodeShareFile(text));
    }
    throw const FormatException('认不出这个文件：需要 .tgz 安装包或 .dshgo 分享码。');
  }

  static String _nameFromPath(String path) {
    var base = path.split(Platform.pathSeparator).last;
    for (final suffix in ['.tar.gz', '.tgz', '.tar']) {
      if (base.toLowerCase().endsWith(suffix)) {
        base = base.substring(0, base.length - suffix.length);
        break;
      }
    }
    // dsh-plugin-import-1730000000000 → 就保留原名，装完以宿主报的包名为准
    return base.isEmpty ? 'dsh-plugin' : base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final input = _parsed;
    final blocked = input == null ? null : _blockedReason(input);
    final accepted = _inspection is PluginInspectionAccepted ? _inspection as PluginInspectionAccepted : null;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(0, 0, 0, MediaQuery.viewInsetsOf(context).bottom + 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHeader('导入插件'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '市场之外的来源。在线导入会先向宿主核对包信息；文件导入支持 .tgz 安装包和 .dshgo 分享码。',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _input,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: InputDecoration(
                      labelText: '在线导入',
                      hintText: 'dsh-plugin-x@1.2.3 / github.com/a/b / https://…/x.tgz',
                      border: const OutlineInputBorder(),
                      helperText: input?.kind.hint,
                      helperMaxLines: 2,
                    ),
                    onSubmitted: (_) => unawaited(_check()),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton.tonal(
                        onPressed: input == null || _checking || blocked != null ? null : () => unawaited(_check()),
                        child: Text(_checking ? '核对中…' : '核对'),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: accepted == null || blocked != null ? null : _install,
                        child: const Text('安装'),
                      ),
                    ],
                  ),
                  if (blocked != null) ...[
                    const SizedBox(height: 10),
                    _Note(blocked, tone: _NoteTone.warn),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    _Note(_error!, tone: _NoteTone.error),
                  ],
                  if (_inspection case final PluginInspectionAccepted ok) ...[
                    const SizedBox(height: 12),
                    _Note(acceptedText(ok), tone: _NoteTone.ok),
                  ],
                  if (_inspection case final PluginInspectionRefused no) ...[
                    const SizedBox(height: 12),
                    _Note(refusedText(no), tone: _NoteTone.error),
                  ],
                  const SizedBox(height: 20),
                  const Divider(height: 1),
                  const SizedBox(height: 16),
                  Text('文件导入', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    '选一个 .tgz 插件包，或一个 .dshgo 分享码。分享码会打开导入确认面板。',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _picking ? null : () => unawaited(_pickFile()),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(_picking ? '读取中…' : '选择文件'),
                  ),
                  const SizedBox(height: 18),
                  if (input != null) PluginCommandBox(command: 'dsh plugin --profile web add ${input.spec}'),
                  const SizedBox(height: 8),
                  Text(
                    '这条命令等价于上面的安装，可以直接在那台机器上执行。',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 宿主核对通过后的摘要：包名、版本、是否 bundle，再跟一行描述。
String acceptedText(PluginInspectionAccepted ok) {
  final head = <String>[
    if (ok.name != null && ok.name!.isNotEmpty) ok.name! else '（未报包名）',
    if (ok.version != null && ok.version!.isNotEmpty) '@ ${ok.version}',
    if (ok.bundle == true) 'bundle',
  ].join(' · ');
  final description = ok.description;
  return description == null || description.isEmpty ? head : '$head\n$description';
}

/// 宿主拒绝时的两行：问题与原因。
String refusedText(PluginInspectionRefused no) =>
    no.reason.isEmpty ? no.problem : '${no.problem}\n${no.reason}';

enum _NoteTone { ok, warn, error }

class _Note extends StatelessWidget {
  const _Note(this.text, {required this.tone});

  final String text;
  final _NoteTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final (bg, fg) = switch (tone) {
      _NoteTone.ok => (colors.successContainer, colors.onSuccessContainer),
      _NoteTone.warn => (colors.warningContainer, colors.onWarningContainer),
      _NoteTone.error => (colors.dangerContainer, colors.onDangerContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: fg, height: 1.6)),
    );
  }
}
