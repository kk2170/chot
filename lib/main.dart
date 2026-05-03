import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const ChotApp());
}

class ChotApp extends StatelessWidget {
  const ChotApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF6D5EF8);

    return MaterialApp(
      title: 'chot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF6F4FF),
        useMaterial3: true,
      ),
      home: const ChotHomePage(),
    );
  }
}

class ChotHomePage extends StatefulWidget {
  const ChotHomePage({super.key});

  @override
  State<ChotHomePage> createState() => _ChotHomePageState();
}

class _ChotHomePageState extends State<ChotHomePage> {
  static const _stateStorageKey = 'chot_notes_state_v1';
  static const _legacyMessagesKey = 'chot_messages';
  static const _sendShortcutKey = 'chot_send_shortcut_v1';
  static const _wideLayoutWidth = 920.0;
  static const _threadPaneWidth = 360.0;

  final TextEditingController _textController = TextEditingController();
  final TextEditingController _threadTextController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _threadScrollController = ScrollController();
  String? _pendingImagePath;
  String? _pendingThreadImagePath;

  List<MemoNote> _notes = const [];
  String? _selectedNoteId;
  String? _selectedThreadRootId;
  SendShortcutMode _sendShortcutMode = SendShortcutMode.enter;
  bool _isLoading = true;

  MemoNote? get _selectedNote {
    final selectedId = _selectedNoteId;
    if (selectedId != null) {
      for (final note in _notes) {
        if (note.id == selectedId) {
          return note;
        }
      }
    }

    if (_notes.isEmpty) {
      return null;
    }

    return _notes.first;
  }

  MemoMessage? get _selectedThreadRoot {
    final note = _selectedNote;
    final threadRootId = _selectedThreadRootId;
    if (note == null || threadRootId == null) {
      return null;
    }

    for (final message in rootMessagesForNote(note)) {
      if (message.id == threadRootId) {
        return message;
      }
    }

    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  @override
  void dispose() {
    _textController.dispose();
    _threadTextController.dispose();
    _scrollController.dispose();
    _threadScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final encodedState = prefs.getString(_stateStorageKey);
    final storedSendShortcut = prefs.getString(_sendShortcutKey);

    _sendShortcutMode = SendShortcutMode.fromStorageValue(storedSendShortcut);

    List<MemoNote>? notes;
    String? selectedNoteId;

    if (encodedState != null && encodedState.isNotEmpty) {
      try {
        final decodedState = MemoAppState.fromJson(
          jsonDecode(encodedState) as Map<String, dynamic>,
        );
        notes = _sortNotes(decodedState.notes);
        if (notes.isEmpty) {
          final note = MemoNote.create(title: 'ノート 1');
          notes = [note];
          selectedNoteId = note.id;
        } else {
          selectedNoteId =
              notes.any((note) => note.id == decodedState.selectedNoteId)
                  ? decodedState.selectedNoteId
                  : notes.first.id;
        }
      } catch (_) {
        await prefs.remove(_stateStorageKey);
      }
    }

    if (notes == null || selectedNoteId == null) {
      final legacyMessages = _loadLegacyMessages(prefs);
      if (legacyMessages.isEmpty) {
        final note = MemoNote.create(title: 'ノート 1');
        notes = [note];
        selectedNoteId = note.id;
      } else {
        final note = MemoNote.create(
          title: 'ノート 1',
          messages: legacyMessages,
          createdAt: legacyMessages.first.createdAt,
          updatedAt: legacyMessages.last.createdAt,
        );
        notes = [note];
        selectedNoteId = note.id;
        await prefs.remove(_legacyMessagesKey);
      }

      await _persistSpecificState(notes, selectedNoteId);
    }

    final resolvedNotes = notes;
    final resolvedSelectedNoteId = selectedNoteId;

    if (!mounted) {
      return;
    }

    setState(() {
      _notes = resolvedNotes;
      _selectedNoteId = resolvedSelectedNoteId;
      _isLoading = false;
    });

    _scrollToBottom(jump: true);
  }

  List<MemoMessage> _loadLegacyMessages(SharedPreferences prefs) {
    final jsonList = prefs.getStringList(_legacyMessagesKey) ?? <String>[];

    return jsonList
        .map((item) =>
            MemoMessage.fromJson(jsonDecode(item) as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Future<void> _sendMessage() async {
    final note = _selectedNote;
    final text = _textController.text.trim();
    final pendingImagePath = _pendingImagePath;
    if (note == null || (text.isEmpty && pendingImagePath == null)) {
      return;
    }

    final now = DateTime.now();
    final storedImagePath = pendingImagePath == null
        ? null
        : await _saveImageToAppStorage(pendingImagePath);
    final message = MemoMessage(
      id: now.microsecondsSinceEpoch.toString(),
      text: text,
      createdAt: now,
      imagePath: storedImagePath,
    );

    final updatedNote = note.copyWith(
      updatedAt: now,
      messages: [...note.messages, message],
    );

    final updatedNotes = _sortNotes(
      _notes
          .map((existingNote) =>
              existingNote.id == note.id ? updatedNote : existingNote)
          .toList(),
    );

    setState(() {
      _notes = updatedNotes;
      _selectedNoteId = updatedNote.id;
      _pendingImagePath = null;
    });

    _textController.clear();
    await _persistState();
    _scrollToBottom();
  }

  Future<void> _editMessage(MemoMessage message) async {
    final note = _selectedNote;
    if (note == null) {
      return;
    }

    final updatedText = await _showEditMessageDialog(
      context,
      title: message.parentId == null ? '投稿を編集' : '返信を編集',
      initialText: message.text,
    );
    if (!mounted || updatedText == null) {
      return;
    }

    final trimmedText = updatedText.trim();
    if (trimmedText.isEmpty || trimmedText == message.text) {
      return;
    }

    final updatedNote = note.copyWith(
      updatedAt: DateTime.now(),
      messages: note.messages
          .map(
            (existingMessage) => existingMessage.id == message.id
                ? existingMessage.copyWith(text: trimmedText)
                : existingMessage,
          )
          .toList(),
    );

    await _applyUpdatedNote(updatedNote);
  }

  Future<void> _deleteMessage(MemoMessage message) async {
    final note = _selectedNote;
    if (note == null) {
      return;
    }

    final removedIds = <String>{message.id};
    if (message.parentId == null) {
      removedIds.addAll(
        threadRepliesForMessage(note, message.id).map((reply) => reply.id),
      );
    }

    final removedMessages = note.messages
        .where((existingMessage) => removedIds.contains(existingMessage.id))
        .toList();
    for (final removedMessage in removedMessages) {
      await _deleteStoredImageIfPresent(removedMessage.imagePath);
    }

    final updatedNote = note.copyWith(
      updatedAt: DateTime.now(),
      messages: note.messages
          .where((existingMessage) => !removedIds.contains(existingMessage.id))
          .toList(),
    );

    final nextThreadRootId = removedIds.contains(_selectedThreadRootId)
        ? null
        : _selectedThreadRootId;

    await _applyUpdatedNote(
      updatedNote,
      selectedThreadRootId: nextThreadRootId,
    );

    if (nextThreadRootId == null) {
      _threadTextController.clear();
    }
  }

  Future<void> _sendThreadReply() async {
    final note = _selectedNote;
    final threadRoot = _selectedThreadRoot;
    final text = _threadTextController.text.trim();
    final pendingImagePath = _pendingThreadImagePath;
    if (note == null ||
        threadRoot == null ||
        (text.isEmpty && pendingImagePath == null)) {
      return;
    }

    final now = DateTime.now();
    final storedImagePath = pendingImagePath == null
        ? null
        : await _saveImageToAppStorage(pendingImagePath);
    final reply = MemoMessage(
      id: now.microsecondsSinceEpoch.toString(),
      text: text,
      createdAt: now,
      parentId: threadRoot.id,
      imagePath: storedImagePath,
    );

    final updatedNote = note.copyWith(
      updatedAt: now,
      messages: [...note.messages, reply],
    );

    final updatedNotes = _sortNotes(
      _notes
          .map((existingNote) =>
              existingNote.id == note.id ? updatedNote : existingNote)
          .toList(),
    );

    setState(() {
      _notes = updatedNotes;
      _selectedNoteId = updatedNote.id;
      _pendingThreadImagePath = null;
    });

    _threadTextController.clear();
    await _persistState();
    _scrollThreadToBottom();
  }

  Future<void> _createNote() async {
    final note = MemoNote.create(title: _nextNoteTitle());

    setState(() {
      _notes = [note, ..._notes];
      _selectedNoteId = note.id;
      _selectedThreadRootId = null;
      _textController.clear();
      _threadTextController.clear();
      _pendingImagePath = null;
      _pendingThreadImagePath = null;
    });

    await _persistState();
    _scrollToBottom(jump: true);
  }

  Future<void> _selectNote(String noteId) async {
    if (_selectedNoteId == noteId) {
      return;
    }

    setState(() {
      _selectedNoteId = noteId;
      _selectedThreadRootId = null;
      _textController.clear();
      _threadTextController.clear();
      _pendingImagePath = null;
      _pendingThreadImagePath = null;
    });

    await _persistState();
    _scrollToBottom(jump: true);
  }

  void _openThread(String threadRootId) {
    setState(() {
      _selectedThreadRootId = threadRootId;
      _threadTextController.clear();
      _pendingThreadImagePath = null;
    });

    _scrollThreadToBottom(jump: true);
  }

  void _closeThread() {
    setState(() {
      _selectedThreadRootId = null;
      _threadTextController.clear();
      _pendingThreadImagePath = null;
    });
  }

  Future<void> _pickImage({required bool forThread}) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'images',
          extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'],
        ),
      ],
    );
    if (!mounted || file == null) {
      return;
    }

    setState(() {
      if (forThread) {
        _pendingThreadImagePath = file.path;
      } else {
        _pendingImagePath = file.path;
      }
    });
  }

  void _clearPendingImage({required bool forThread}) {
    setState(() {
      if (forThread) {
        _pendingThreadImagePath = null;
      } else {
        _pendingImagePath = null;
      }
    });
  }

  Future<String> _saveImageToAppStorage(String sourcePath) async {
    final directory = await getApplicationDocumentsDirectory();
    final attachmentsDirectory = Directory(
      p.join(directory.path, 'chot_attachments'),
    );
    if (!await attachmentsDirectory.exists()) {
      await attachmentsDirectory.create(recursive: true);
    }

    final extension = p.extension(sourcePath);
    final targetPath = p.join(
      attachmentsDirectory.path,
      '${DateTime.now().microsecondsSinceEpoch}$extension',
    );

    await File(sourcePath).copy(targetPath);
    return targetPath;
  }

  Future<void> _deleteStoredImageIfPresent(String? imagePath) async {
    if (imagePath == null) {
      return;
    }

    final file = File(imagePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _shareCurrentNote() async {
    final note = _selectedNote;
    if (note == null || note.messages.isEmpty) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('シェアする前にメモを書いてください。')),
      );
      return;
    }

    try {
      await SharePlus.instance.share(
        ShareParams(
          text: buildShareText(note),
          subject: note.title,
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この端末ではシェアを開けませんでした。')),
      );
    }
  }

  Future<void> _copyCurrentNoteAsMarkdown() async {
    final note = _selectedNote;
    if (note == null || note.messages.isEmpty) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('コピーする前にメモを書いてください。')),
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: buildMarkdownForNote(note)));

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Markdown をコピーしました。')),
    );
  }

  Future<void> _updateSendShortcutMode(SendShortcutMode mode) async {
    if (_sendShortcutMode == mode) {
      return;
    }

    setState(() {
      _sendShortcutMode = mode;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sendShortcutKey, mode.storageValue);
  }

  Future<void> _renameCurrentNote() async {
    final note = _selectedNote;
    if (note == null) {
      return;
    }

    final renamedTitle = await _showRenameNoteDialog(
      context,
      initialTitle: note.title,
    );
    if (!mounted || renamedTitle == null) {
      return;
    }

    final trimmedTitle = renamedTitle.trim();
    if (trimmedTitle.isEmpty || trimmedTitle == note.title) {
      return;
    }

    final updatedNote = note.copyWith(
      title: trimmedTitle,
      updatedAt: DateTime.now(),
    );

    setState(() {
      _notes = _sortNotes(
        _notes
            .map((existingNote) =>
                existingNote.id == note.id ? updatedNote : existingNote)
            .toList(),
      );
      _selectedNoteId = updatedNote.id;
    });

    await _persistState();
  }

  Future<void> _deleteCurrentNote() async {
    final note = _selectedNote;
    if (note == null) {
      return;
    }

    final shouldDelete = await _showDeleteNoteDialog(
      context,
      noteTitle: note.title,
    );
    if (!mounted || shouldDelete != true) {
      return;
    }

    for (final message in note.messages) {
      await _deleteStoredImageIfPresent(message.imagePath);
    }

    final remainingNotes = _notes.where((item) => item.id != note.id).toList();
    final nextNotes = remainingNotes.isEmpty
        ? [MemoNote.create(title: 'ノート 1')]
        : _sortNotes(remainingNotes);
    final nextSelectedNoteId = nextNotes.first.id;

    setState(() {
      _notes = nextNotes;
      _selectedNoteId = nextSelectedNoteId;
      _selectedThreadRootId = null;
      _textController.clear();
      _threadTextController.clear();
      _pendingImagePath = null;
      _pendingThreadImagePath = null;
    });

    await _persistState();
  }

  Future<void> _applyUpdatedNote(
    MemoNote updatedNote, {
    String? selectedThreadRootId,
  }) async {
    final updatedNotes = _sortNotes(
      _notes
          .map((existingNote) =>
              existingNote.id == updatedNote.id ? updatedNote : existingNote)
          .toList(),
    );

    setState(() {
      _notes = updatedNotes;
      _selectedNoteId = updatedNote.id;
      _selectedThreadRootId = selectedThreadRootId ?? _selectedThreadRootId;
    });

    await _persistState();
  }

  Future<void> _persistState() async {
    await _persistSpecificState(_notes, _selectedNote?.id ?? '');
  }

  Future<void> _persistSpecificState(
      List<MemoNote> notes, String selectedNoteId) async {
    final prefs = await SharedPreferences.getInstance();
    final encodedState = jsonEncode(
      MemoAppState(
        selectedNoteId: selectedNoteId,
        notes: notes,
      ).toJson(),
    );
    await prefs.setString(_stateStorageKey, encodedState);
  }

  String _nextNoteTitle() {
    var index = _notes.length + 1;
    while (_notes.any((note) => note.title == 'ノート $index')) {
      index += 1;
    }
    return 'ノート $index';
  }

  List<MemoNote> _sortNotes(List<MemoNote> notes) {
    final sorted = [...notes];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  }

  void _scrollToBottom({bool jump = false}) {
    _scrollControllerToEnd(_scrollController, jump: jump);
  }

  void _scrollThreadToBottom({bool jump = false}) {
    _scrollControllerToEnd(_threadScrollController, jump: jump);
  }

  void _scrollControllerToEnd(ScrollController controller,
      {bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) {
        return;
      }

      final position = controller.position.maxScrollExtent;
      if (jump) {
        controller.jumpTo(position);
      } else {
        controller.animateTo(
          position,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedNote = _selectedNote;
    final selectedThreadRoot = _selectedThreadRoot;

    return LayoutBuilder(
      builder: (context, constraints) {
        final navigator = Navigator.of(context);
        final isWideLayout = constraints.maxWidth >= _wideLayoutWidth;
        final threadPaneVisible = isWideLayout && selectedThreadRoot != null;

        return Scaffold(
          appBar: AppBar(
            title: Text(
              selectedNote == null ? 'chot' : 'chot · ${selectedNote.title}',
            ),
            actions: [
              IconButton(
                tooltip: 'タイトル変更',
                onPressed: _renameCurrentNote,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'ノート削除',
                onPressed: _deleteCurrentNote,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
              IconButton(
                tooltip: 'シェア',
                onPressed: _shareCurrentNote,
                icon: const Icon(Icons.ios_share_rounded),
              ),
              IconButton(
                tooltip: 'Markdownをコピー',
                onPressed: _copyCurrentNoteAsMarkdown,
                icon: const Icon(Icons.content_copy_rounded),
              ),
              PopupMenuButton<SendShortcutMode>(
                tooltip: '送信キー設定',
                initialValue: _sendShortcutMode,
                onSelected: (mode) async {
                  await _updateSendShortcutMode(mode);
                },
                itemBuilder: (context) {
                  return SendShortcutMode.values
                      .map(
                        (mode) => CheckedPopupMenuItem<SendShortcutMode>(
                          value: mode,
                          checked: mode == _sendShortcutMode,
                          child: Text(mode.menuLabel),
                        ),
                      )
                      .toList();
                },
                icon: const Icon(Icons.keyboard_return_rounded),
              ),
              IconButton(
                tooltip: '新規ノート',
                onPressed: _createNote,
                icon: const Icon(Icons.note_add_outlined),
              ),
            ],
          ),
          drawer: isWideLayout
              ? null
              : Drawer(
                  child: SafeArea(
                    child: _NotesPanel(
                      notes: _notes,
                      selectedNoteId: _selectedNoteId,
                      onCreateNote: () async {
                        await _createNote();
                        if (mounted) {
                          navigator.pop();
                        }
                      },
                      onSelectNote: (noteId) async {
                        await _selectNote(noteId);
                        if (mounted) {
                          navigator.pop();
                        }
                      },
                    ),
                  ),
                ),
          body: SafeArea(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    children: [
                      if (isWideLayout)
                        SizedBox(
                          width: 320,
                          child: _NotesPanel(
                            notes: _notes,
                            selectedNoteId: _selectedNoteId,
                            onCreateNote: _createNote,
                            onSelectNote: _selectNote,
                          ),
                        ),
                      if (isWideLayout)
                        const VerticalDivider(width: 1, thickness: 1),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: selectedThreadRoot != null && !isWideLayout
                                ? _ThreadView(
                                    note: selectedNote,
                                    threadRoot: selectedThreadRoot,
                                    replies: selectedNote == null
                                        ? const []
                                        : threadRepliesForMessage(
                                            selectedNote,
                                            selectedThreadRoot.id,
                                          ),
                                    textController: _threadTextController,
                                    scrollController: _threadScrollController,
                                    onClose: _closeThread,
                                    onEditMessage: _editMessage,
                                    onDeleteMessage: _deleteMessage,
                                    selectedImagePath: _pendingThreadImagePath,
                                    onPickImage: () =>
                                        _pickImage(forThread: true),
                                    onClearImage: () =>
                                        _clearPendingImage(forThread: true),
                                    sendShortcutMode: _sendShortcutMode,
                                    onSendReply: _sendThreadReply,
                                  )
                                : _NoteConversation(
                                    note: selectedNote,
                                    onRename: _renameCurrentNote,
                                    onEditMessage: _editMessage,
                                    onDeleteMessage: _deleteMessage,
                                    activeThreadRootId: _selectedThreadRootId,
                                    onOpenThread: _openThread,
                                    selectedImagePath: _pendingImagePath,
                                    onPickImage: () =>
                                        _pickImage(forThread: false),
                                    onClearImage: () =>
                                        _clearPendingImage(forThread: false),
                                    sendShortcutMode: _sendShortcutMode,
                                    textController: _textController,
                                    scrollController: _scrollController,
                                    onSend: _sendMessage,
                                  ),
                          ),
                        ),
                      ),
                      if (threadPaneVisible)
                        const VerticalDivider(width: 1, thickness: 1),
                      if (threadPaneVisible)
                        SizedBox(
                          width: _threadPaneWidth,
                          child: _ThreadView(
                            note: selectedNote,
                            threadRoot: selectedThreadRoot,
                            replies: selectedNote == null
                                ? const []
                                : threadRepliesForMessage(
                                    selectedNote,
                                    selectedThreadRoot.id,
                                  ),
                            textController: _threadTextController,
                            scrollController: _threadScrollController,
                            onClose: _closeThread,
                            onEditMessage: _editMessage,
                            onDeleteMessage: _deleteMessage,
                            selectedImagePath: _pendingThreadImagePath,
                            onPickImage: () => _pickImage(forThread: true),
                            onClearImage: () =>
                                _clearPendingImage(forThread: true),
                            sendShortcutMode: _sendShortcutMode,
                            onSendReply: _sendThreadReply,
                          ),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _NotesPanel extends StatelessWidget {
  const _NotesPanel({
    required this.notes,
    required this.selectedNoteId,
    required this.onCreateNote,
    required this.onSelectNote,
  });

  final List<MemoNote> notes;
  final String? selectedNoteId;
  final Future<void> Function() onCreateNote;
  final Future<void> Function(String noteId) onSelectNote;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF24163A),
        border: Border(
          right: BorderSide(color: Colors.white.withAlpha(20)),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'chot workspace',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Colors.white60,
                        letterSpacing: 0.3,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'notes',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${notes.length}件のノート',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white54,
                      ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onCreateNote,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7C5CFF),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('ノート追加'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white24),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: notes.length,
              itemBuilder: (context, index) {
                final note = notes[index];
                final isSelected = note.id == selectedNoteId;
                final preview = note.messages.isEmpty
                    ? 'まだメモはありません'
                    : messagePreview(note.messages.last);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: isSelected
                        ? const Color(0xFF4B3384)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onSelectNote(note.id),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    note.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: isSelected
                                              ? Colors.white
                                              : Colors.white70,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${note.messages.length}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium
                                      ?.copyWith(
                                        color: isSelected
                                            ? Colors.white70
                                            : Colors.white38,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: isSelected
                                        ? Colors.white70
                                        : Colors.white38,
                                    height: 1.45,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _formatDateTime(note.updatedAt),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: isSelected
                                        ? Colors.white60
                                        : Colors.white30,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteConversation extends StatelessWidget {
  const _NoteConversation({
    required this.note,
    required this.onRename,
    required this.onEditMessage,
    required this.onDeleteMessage,
    required this.activeThreadRootId,
    required this.onOpenThread,
    required this.selectedImagePath,
    required this.onPickImage,
    required this.onClearImage,
    required this.sendShortcutMode,
    required this.textController,
    required this.scrollController,
    required this.onSend,
  });

  final MemoNote? note;
  final Future<void> Function() onRename;
  final Future<void> Function(MemoMessage message) onEditMessage;
  final Future<void> Function(MemoMessage message) onDeleteMessage;
  final String? activeThreadRootId;
  final void Function(String threadRootId) onOpenThread;
  final String? selectedImagePath;
  final Future<void> Function() onPickImage;
  final VoidCallback onClearImage;
  final SendShortcutMode sendShortcutMode;
  final TextEditingController textController;
  final ScrollController scrollController;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final currentNote = note;
    if (currentNote == null) {
      return const SizedBox.shrink();
    }

    final rootMessages = rootMessagesForNote(currentNote);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
          child: _CurrentNoteHeader(
            note: currentNote,
            onRename: onRename,
            rootMessageCount: rootMessages.length,
            threadReplyCount: currentNote.messages.length - rootMessages.length,
          ),
        ),
        Expanded(
          child: rootMessages.isEmpty
              ? _EmptyState(noteTitle: currentNote.title)
              : ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  itemCount: rootMessages.length,
                  itemBuilder: (context, index) {
                    final message = rootMessages[index];
                    final replyCount =
                        threadRepliesForMessage(currentNote, message.id).length;
                    return _MessageBubble(
                      message: message,
                      replyCount: replyCount,
                      isThreadActive: activeThreadRootId == message.id,
                      onOpenThread: () => onOpenThread(message.id),
                      onEdit: () => onEditMessage(message),
                      onDelete: () => onDeleteMessage(message),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.06),
                  blurRadius: 20,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selectedImagePath != null) ...[
                    _AttachmentPreview(
                      imagePath: selectedImagePath!,
                      onClear: onClearImage,
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: '画像を追加',
                        onPressed: onPickImage,
                        icon: const Icon(Icons.image_outlined),
                      ),
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: buildSendShortcutBindings(
                            mode: sendShortcutMode,
                            onSend: onSend,
                          ),
                          child: Focus(
                            onKeyEvent: (node, event) {
                              return handleComposerKeyEvent(
                                mode: sendShortcutMode,
                                event: event,
                                controller: textController,
                                onSend: onSend,
                              );
                            },
                            child: TextField(
                              controller: textController,
                              minLines: 1,
                              maxLines: 6,
                              textInputAction: TextInputAction.newline,
                              decoration: InputDecoration(
                                hintText: '${currentNote.title} にメッセージを書く...',
                                helperText: sendShortcutMode.helperText,
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: onSend,
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          padding: const EdgeInsets.all(14),
                        ),
                        child: const Icon(Icons.arrow_upward_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ThreadView extends StatelessWidget {
  const _ThreadView({
    required this.note,
    required this.threadRoot,
    required this.replies,
    required this.textController,
    required this.scrollController,
    required this.onClose,
    required this.onEditMessage,
    required this.onDeleteMessage,
    required this.selectedImagePath,
    required this.onPickImage,
    required this.onClearImage,
    required this.sendShortcutMode,
    required this.onSendReply,
  });

  final MemoNote? note;
  final MemoMessage threadRoot;
  final List<MemoMessage> replies;
  final TextEditingController textController;
  final ScrollController scrollController;
  final VoidCallback onClose;
  final Future<void> Function(MemoMessage message) onEditMessage;
  final Future<void> Function(MemoMessage message) onDeleteMessage;
  final String? selectedImagePath;
  final Future<void> Function() onPickImage;
  final VoidCallback onClearImage;
  final SendShortcutMode sendShortcutMode;
  final Future<void> Function() onSendReply;

  @override
  Widget build(BuildContext context) {
    final currentNote = note;

    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.white),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'スレッドを閉じる',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'スレッド',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      Text(
                        '${replies.length}件の返信',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.black54,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              itemCount: replies.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ThreadMessageCard(
                        message: threadRoot,
                        isRoot: true,
                        onEdit: () => onEditMessage(threadRoot),
                        onDelete: () => onDeleteMessage(threadRoot),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(44, 8, 0, 12),
                        child: Text('返信'),
                      ),
                    ],
                  );
                }

                final reply = replies[index - 1];
                return _ThreadMessageCard(
                  message: reply,
                  onEdit: () => onEditMessage(reply),
                  onDelete: () => onDeleteMessage(reply),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFF7F7FB),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selectedImagePath != null) ...[
                      _AttachmentPreview(
                        imagePath: selectedImagePath!,
                        onClear: onClearImage,
                      ),
                      const SizedBox(height: 10),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: '画像を追加',
                          onPressed: onPickImage,
                          icon: const Icon(Icons.image_outlined),
                        ),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: buildSendShortcutBindings(
                              mode: sendShortcutMode,
                              onSend: onSendReply,
                            ),
                            child: Focus(
                              onKeyEvent: (node, event) {
                                return handleComposerKeyEvent(
                                  mode: sendShortcutMode,
                                  event: event,
                                  controller: textController,
                                  onSend: onSendReply,
                                );
                              },
                              child: TextField(
                                controller: textController,
                                minLines: 1,
                                maxLines: 5,
                                textInputAction: TextInputAction.newline,
                                decoration: InputDecoration(
                                  hintText: currentNote == null
                                      ? 'スレッドに返信する...'
                                      : '${currentNote.title} のスレッドに返信する...',
                                  helperText: sendShortcutMode.helperText,
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        FilledButton(
                          onPressed: onSendReply,
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(12),
                          ),
                          child: const Icon(Icons.reply_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentNoteHeader extends StatelessWidget {
  const _CurrentNoteHeader({
    required this.note,
    required this.onRename,
    required this.rootMessageCount,
    required this.threadReplyCount,
  });

  final MemoNote note;
  final Future<void> Function() onRename;
  final int rootMessageCount;
  final int threadReplyCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outlineVariant.withAlpha(100)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(
                Icons.sticky_note_2_outlined,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    note.messages.isEmpty
                        ? 'このノートはまだ空です'
                        : '$rootMessageCount件の投稿 · $threadReplyCount件の返信 · 最終更新 ${_formatDateTime(note.updatedAt)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.black54,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'タイトル変更',
              onPressed: onRename,
              icon: const Icon(Icons.drive_file_rename_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.noteTitle});

  final String noteTitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 34,
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(
                Icons.forum_rounded,
                size: 32,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '$noteTitle に、最初の投稿を。',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Slackみたいに投稿して、\n必要な話題はスレッドで深掘りできます。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black54,
                    height: 1.6,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.message,
    required this.replyCount,
    required this.isThreadActive,
    required this.onOpenThread,
    required this.onEdit,
    required this.onDelete,
  });

  final MemoMessage message;
  final int replyCount;
  final bool isThreadActive;
  final VoidCallback onOpenThread;
  final Future<void> Function() onEdit;
  final Future<void> Function() onDelete;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final timeLabel = _formatTime(widget.message.createdAt);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person_rounded,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'you',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            timeLabel,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Colors.black45,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: widget.isThreadActive
                                ? colorScheme.primary
                                : colorScheme.outlineVariant.withAlpha(110),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.message.imagePath != null) ...[
                                _MessageImage(path: widget.message.imagePath!),
                                if (widget.message.text.isNotEmpty)
                                  const SizedBox(height: 10),
                              ],
                              if (widget.message.text.isNotEmpty)
                                Text(
                                  widget.message.text,
                                  style: const TextStyle(
                                    color: Color(0xFF18181B),
                                    height: 1.5,
                                  ),
                                ),
                              if (widget.message.text.isEmpty &&
                                  widget.message.imagePath != null)
                                Text(
                                  '画像を送信',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (widget.replyCount > 0) ...[
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: InkWell(
                            onTap: widget.onOpenThread,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Text(
                                '返信 ${widget.replyCount}件',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Colors.black45,
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              top: -10,
              right: 0,
              child: IgnorePointer(
                ignoring: !(_isHovered || widget.isThreadActive),
                child: AnimatedOpacity(
                  opacity: (_isHovered || widget.isThreadActive) ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: _HoverActionBar(
                    actions: [
                      _HoverActionItem(
                        icon: Icons.forum_outlined,
                        label: widget.replyCount == 0 ? 'スレッド開始' : 'スレッド',
                        onTap: widget.onOpenThread,
                      ),
                      _HoverActionItem(
                        icon: Icons.edit_outlined,
                        label: '編集',
                        onTap: () {
                          widget.onEdit();
                        },
                      ),
                      _HoverActionItem(
                        icon: Icons.delete_outline_rounded,
                        label: '削除',
                        isDestructive: true,
                        onTap: () {
                          widget.onDelete();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThreadMessageCard extends StatefulWidget {
  const _ThreadMessageCard({
    required this.message,
    required this.onEdit,
    required this.onDelete,
    this.isRoot = false,
  });

  final MemoMessage message;
  final bool isRoot;
  final Future<void> Function() onEdit;
  final Future<void> Function() onDelete;

  @override
  State<_ThreadMessageCard> createState() => _ThreadMessageCardState();
}

class _ThreadMessageCardState extends State<_ThreadMessageCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: widget.isRoot ? 0 : 10),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: widget.isRoot
                      ? colorScheme.primaryContainer
                      : colorScheme.secondaryContainer,
                  child: Icon(
                    Icons.person_rounded,
                    size: 16,
                    color: widget.isRoot
                        ? colorScheme.primary
                        : colorScheme.secondary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          Text(
                            widget.isRoot ? '親投稿' : '返信',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          Text(
                            _formatDateTime(widget.message.createdAt),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Colors.black45,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.isRoot
                              ? colorScheme.primaryContainer.withAlpha(120)
                              : const Color(0xFFF7F7FB),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.message.imagePath != null) ...[
                                _MessageImage(path: widget.message.imagePath!),
                                if (widget.message.text.isNotEmpty)
                                  const SizedBox(height: 10),
                              ],
                              if (widget.message.text.isNotEmpty)
                                Text(
                                  widget.message.text,
                                  style: const TextStyle(height: 1.5),
                                ),
                              if (widget.message.text.isEmpty &&
                                  widget.message.imagePath != null)
                                Text(
                                  '画像を送信',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              top: -10,
              right: 0,
              child: IgnorePointer(
                ignoring: !_isHovered,
                child: AnimatedOpacity(
                  opacity: _isHovered ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: _HoverActionBar(
                    actions: [
                      _HoverActionItem(
                        icon: Icons.edit_outlined,
                        label: '編集',
                        onTap: () {
                          widget.onEdit();
                        },
                      ),
                      _HoverActionItem(
                        icon: Icons.delete_outline_rounded,
                        label: '削除',
                        isDestructive: true,
                        onTap: () {
                          widget.onDelete();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoverActionBar extends StatelessWidget {
  const _HoverActionBar({required this.actions});

  final List<_HoverActionItem> actions;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.12),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
        border: Border.all(color: Colors.black12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: actions
              .map(
                (action) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: TextButton.icon(
                    onPressed: action.onTap,
                    style: TextButton.styleFrom(
                      foregroundColor: action.isDestructive
                          ? Colors.redAccent
                          : const Color(0xFF2A2340),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                    icon: Icon(action.icon, size: 16),
                    label: Text(action.label),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _HoverActionItem {
  const _HoverActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;
}

enum SendShortcutMode {
  enter,
  shiftEnter;

  String get storageValue => switch (this) {
        SendShortcutMode.enter => 'enter',
        SendShortcutMode.shiftEnter => 'shift_enter',
      };

  String get menuLabel => switch (this) {
        SendShortcutMode.enter => 'Enterで送信',
        SendShortcutMode.shiftEnter => 'Shift+Enterで送信',
      };

  String get helperText => switch (this) {
        SendShortcutMode.enter => 'Enterで送信 / Shift+Enterで改行',
        SendShortcutMode.shiftEnter => 'Shift+Enterで送信 / Enterで改行',
      };

  TextInputAction get textInputAction => switch (this) {
        SendShortcutMode.enter => TextInputAction.send,
        SendShortcutMode.shiftEnter => TextInputAction.newline,
      };

  static SendShortcutMode fromStorageValue(String? value) {
    return switch (value) {
      'shift_enter' => SendShortcutMode.shiftEnter,
      _ => SendShortcutMode.enter,
    };
  }
}

Map<ShortcutActivator, VoidCallback> buildSendShortcutBindings({
  required SendShortcutMode mode,
  required Future<void> Function() onSend,
}) {
  return {
    SingleActivator(
      LogicalKeyboardKey.enter,
      shift: mode == SendShortcutMode.shiftEnter,
    ): () {
      onSend();
    },
  };
}

KeyEventResult handleComposerKeyEvent({
  required SendShortcutMode mode,
  required KeyEvent event,
  required TextEditingController controller,
  required Future<void> Function() onSend,
}) {
  if (event is! KeyDownEvent) {
    return KeyEventResult.ignored;
  }

  final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;
  if (!isEnter) {
    return KeyEventResult.ignored;
  }

  final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;

  if (mode == SendShortcutMode.enter) {
    if (isShiftPressed) {
      insertNewlineAtSelection(controller);
    } else {
      onSend();
    }
    return KeyEventResult.handled;
  }

  if (isShiftPressed) {
    onSend();
    return KeyEventResult.handled;
  }

  return KeyEventResult.ignored;
}

void insertNewlineAtSelection(TextEditingController controller) {
  final selection = controller.selection;
  final text = controller.text;
  final start = selection.start >= 0 ? selection.start : text.length;
  final end = selection.end >= 0 ? selection.end : text.length;
  final newText = text.replaceRange(start, end, '\n');
  final offset = start + 1;
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: offset),
  );
}

List<MemoMessage> rootMessagesForNote(MemoNote note) {
  final roots =
      note.messages.where((message) => message.parentId == null).toList();
  roots.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return roots;
}

List<MemoMessage> threadRepliesForMessage(MemoNote note, String rootMessageId) {
  final replies = note.messages
      .where((message) => message.parentId == rootMessageId)
      .toList();
  replies.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return replies;
}

String buildShareText(MemoNote note) {
  final lines = <String>[note.title, ''];

  for (final message in rootMessagesForNote(note)) {
    lines.add(
        '[${_formatDateTime(message.createdAt)}] ${shareTextForMessage(message)}');
    for (final reply in threadRepliesForMessage(note, message.id)) {
      lines.add(
          '  ↳ [${_formatDateTime(reply.createdAt)}] ${shareTextForMessage(reply)}');
    }
    lines.add('');
  }

  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  return lines.join('\n');
}

String buildMarkdownForNote(MemoNote note) {
  final lines = <String>['# ${note.title}', ''];

  for (final message in rootMessagesForNote(note)) {
    lines.add('## ${_formatDateTime(message.createdAt)}');
    if (message.text.trim().isNotEmpty) {
      lines.add(message.text);
    }
    if (message.imagePath != null) {
      lines.add('![](${message.imagePath})');
    }

    final replies = threadRepliesForMessage(note, message.id);
    if (replies.isNotEmpty) {
      lines.add('');
      lines.add('### Thread');
      for (final reply in replies) {
        lines.add('- ${_formatDateTime(reply.createdAt)}');
        if (reply.text.trim().isNotEmpty) {
          lines.add('  ${reply.text}');
        }
        if (reply.imagePath != null) {
          lines.add('  ![](${reply.imagePath})');
        }
      }
    }

    lines.add('');
  }

  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  return lines.join('\n');
}

String shareTextForMessage(MemoMessage message) {
  final hasText = message.text.trim().isNotEmpty;
  final hasImage = message.imagePath != null;
  if (hasText && hasImage) {
    return '${message.text} [画像]';
  }
  if (hasText) {
    return message.text;
  }
  if (hasImage) {
    return '画像';
  }
  return '';
}

String messagePreview(MemoMessage message) {
  if (message.text.trim().isNotEmpty) {
    return message.text;
  }
  if (message.imagePath != null) {
    return '画像を送信';
  }
  return '空のメッセージ';
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.imagePath, required this.onClear});

  final String imagePath;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(imagePath),
            width: 92,
            height: 92,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                width: 92,
                height: 92,
                color: Colors.black12,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            p.basename(imagePath),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: '画像を削除',
          onPressed: onClear,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

class _MessageImage extends StatelessWidget {
  const _MessageImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        File(path),
        width: 240,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: 240,
            height: 160,
            color: Colors.black12,
            alignment: Alignment.center,
            child: const Icon(Icons.image_not_supported_outlined),
          );
        },
      ),
    );
  }
}

Future<String?> _showRenameNoteDialog(
  BuildContext context, {
  required String initialTitle,
}) async {
  var editedTitle = initialTitle;

  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('ノート名を変更'),
        content: TextFormField(
          autofocus: true,
          initialValue: initialTitle,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'ノート名',
            hintText: 'ノート名を入力',
          ),
          onChanged: (value) {
            editedTitle = value;
          },
          onFieldSubmitted: (value) {
            Navigator.of(dialogContext).pop(value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(editedTitle),
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
}

Future<bool?> _showDeleteNoteDialog(
  BuildContext context, {
  required String noteTitle,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('ノートを削除'),
        content: Text('「$noteTitle」を削除しますか？\nこの操作は元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('削除'),
          ),
        ],
      );
    },
  );
}

Future<String?> _showEditMessageDialog(
  BuildContext context, {
  required String title,
  required String initialText,
}) async {
  var editedText = initialText;

  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(title),
        content: TextFormField(
          autofocus: true,
          initialValue: initialText,
          minLines: 2,
          maxLines: 6,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: '内容',
            hintText: '内容を入力',
          ),
          onChanged: (value) {
            editedText = value;
          },
          onFieldSubmitted: (value) {
            Navigator.of(dialogContext).pop(value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(editedText),
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
}

String _formatDateTime(DateTime dateTime) {
  final month = dateTime.month.toString().padLeft(2, '0');
  final day = dateTime.day.toString().padLeft(2, '0');
  return '$month/$day ${_formatTime(dateTime)}';
}

String _formatTime(DateTime dateTime) {
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

class MemoAppState {
  const MemoAppState({
    required this.selectedNoteId,
    required this.notes,
  });

  final String selectedNoteId;
  final List<MemoNote> notes;

  Map<String, dynamic> toJson() {
    return {
      'selectedNoteId': selectedNoteId,
      'notes': notes.map((note) => note.toJson()).toList(),
    };
  }

  factory MemoAppState.fromJson(Map<String, dynamic> json) {
    return MemoAppState(
      selectedNoteId: json['selectedNoteId'] as String,
      notes: (json['notes'] as List<dynamic>)
          .map((item) => MemoNote.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class MemoNote {
  const MemoNote({
    required this.id,
    required this.title,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MemoNote.create({
    required String title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<MemoMessage> messages = const [],
  }) {
    final now = DateTime.now();
    return MemoNote(
      id: now.microsecondsSinceEpoch.toString(),
      title: title,
      messages: messages,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? now,
    );
  }

  final String id;
  final String title;
  final List<MemoMessage> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  MemoNote copyWith({
    String? id,
    String? title,
    List<MemoMessage>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MemoNote(
      id: id ?? this.id,
      title: title ?? this.title,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'messages': messages.map((message) => message.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory MemoNote.fromJson(Map<String, dynamic> json) {
    return MemoNote(
      id: json['id'] as String,
      title: json['title'] as String,
      messages: (json['messages'] as List<dynamic>)
          .map((item) => MemoMessage.fromJson(item as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

class MemoMessage {
  const MemoMessage({
    required this.id,
    required this.text,
    required this.createdAt,
    this.parentId,
    this.imagePath,
  });

  final String id;
  final String text;
  final DateTime createdAt;
  final String? parentId;
  final String? imagePath;

  MemoMessage copyWith({
    String? id,
    String? text,
    DateTime? createdAt,
    String? parentId,
    String? imagePath,
  }) {
    return MemoMessage(
      id: id ?? this.id,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      parentId: parentId ?? this.parentId,
      imagePath: imagePath ?? this.imagePath,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
      'parentId': parentId,
      'imagePath': imagePath,
    };
  }

  factory MemoMessage.fromJson(Map<String, dynamic> json) {
    return MemoMessage(
      id: json['id'] as String,
      text: json['text'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      parentId: json['parentId'] as String?,
      imagePath: json['imagePath'] as String?,
    );
  }
}
