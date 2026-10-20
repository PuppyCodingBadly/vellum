import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import 'book_details_page.dart';
import 'widgets/book_cover.dart';

/// Shelves (user collections) page.
///
/// Wide layouts show the shelf list beside the selected shelf's books; narrow
/// layouts drill down from the list into a single shelf. Shelf contents use the
/// same [BookCard] grid as the library page.
class ShelvesPage extends StatefulWidget {
  const ShelvesPage({super.key});

  @override
  State<ShelvesPage> createState() => _ShelvesPageState();
}

class _ShelvesPageState extends State<ShelvesPage> {
  static const double _wideBreakpoint = 800;

  int? _selectedShelfId;
  bool _showShelfDetail = false;

  int? _effectiveSelection(
      List<Map<String, Object?>> shelves, {required bool wide}) {
    final requested = _selectedShelfId;
    if (requested != null && shelves.any((s) => s['id'] == requested)) {
      return requested;
    }
    if (wide && shelves.isNotEmpty) return shelves.first['id'] as int;
    return null;
  }

  Future<void> _createShelf(
      AppState appState, List<Map<String, Object?>> shelves) async {
    final existing = shelves
        .map((s) => (s['name'] as String).trim().toLowerCase())
        .toSet();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _ShelfNameDialog(
        title: 'New Shelf',
        actionLabel: 'Create',
        existingNames: existing,
        onInvalid: appState.showToast,
      ),
    );
    if (name == null || !mounted) return;
    final id = appState.library.createShelf(name);
    setState(() {
      _selectedShelfId = id;
      _showShelfDetail = false;
    });
    await appState.refresh();
  }

  Future<void> _renameShelf(AppState appState,
      List<Map<String, Object?>> shelves, Map<String, Object?> shelf) async {
    final id = shelf['id'] as int;
    final currentName = shelf['name'] as String;
    final existing = shelves
        .where((s) => s['id'] != id)
        .map((s) => (s['name'] as String).trim().toLowerCase())
        .toSet();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _ShelfNameDialog(
        title: 'Rename Shelf',
        actionLabel: 'Rename',
        initialName: currentName,
        existingNames: existing,
        onInvalid: appState.showToast,
      ),
    );
    if (name == null || !mounted) return;
    appState.library.renameShelf(id, name);
    await appState.refresh();
    if (mounted) setState(() {});
  }

  Future<void> _deleteShelf(AppState appState, int shelfId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete shelf?'),
        content: const Text('Books stay in the library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    appState.library.deleteShelf(shelfId);
    setState(() {
      if (_selectedShelfId == shelfId) _selectedShelfId = null;
      _showShelfDetail = false;
    });
    await appState.refresh();
  }

  Future<void> _addBooks(AppState appState, int shelfId) async {
    final onShelf = appState.library
        .shelfBooks(shelfId, includeHidden: true)
        .map((b) => b.id)
        .whereType<int>()
        .toSet();
    final candidates = appState.library
        .allBooks(includeHidden: appState.showHidden)
        .where((b) => b.id != null && !onShelf.contains(b.id))
        .toList();
    final selected = await showDialog<List<int>>(
      context: context,
      builder: (_) => _AddBooksDialog(books: candidates),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    for (final bookId in selected) {
      appState.library.addBookToShelf(shelfId, bookId);
    }
    await appState.refresh();
    if (mounted) setState(() {});
  }

  Future<void> _removeFromShelf(
      AppState appState, int shelfId, Book book) async {
    final bookId = book.id;
    if (bookId == null) return;
    appState.library.removeBookFromShelf(shelfId, bookId);
    await appState.refresh();
    if (mounted) setState(() {});
  }

  Future<void> _showBookMenu(
      AppState appState, BuildContext cardContext, int shelfId, Book book) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    final card = cardContext.findRenderObject();
    if (overlay is! RenderBox || card is! RenderBox) return;
    final rect = Rect.fromPoints(
      card.localToGlobal(Offset.zero, ancestor: overlay),
      card.localToGlobal(card.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem<String>(
          value: 'remove',
          child: Text('Remove from shelf'),
        ),
      ],
    );
    if (action == 'remove' && mounted) {
      await _removeFromShelf(appState, shelfId, book);
    }
  }

  void _openBook(Book book) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookDetailsPage(book: book),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppState.of(context);
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final shelves = appState.library.listShelves();
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _wideBreakpoint;
            final selectedId = _effectiveSelection(shelves, wide: wide);
            if (!wide && _showShelfDetail && selectedId != null) {
              return _buildShelfDetail(
                appState,
                shelves,
                selectedId,
                narrow: true,
              );
            }
            final list = _buildShelfList(
              appState,
              shelves,
              selectedId,
              wide: wide,
            );
            if (!wide) return list;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 260, child: list),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selectedId == null
                      ? const Center(child: Text('No shelves yet'))
                      : _buildShelfDetail(
                          appState,
                          shelves,
                          selectedId,
                          narrow: false,
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildShelfList(AppState appState,
      List<Map<String, Object?>> shelves, int? selectedId,
      {required bool wide}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Shelves', style: theme.textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: FilledButton.icon(
            onPressed: () => _createShelf(appState, shelves),
            icon: const Icon(Icons.add),
            label: const Text('New Shelf'),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: shelves.isEmpty
              ? const Center(child: Text('No shelves yet'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: shelves.length,
                  itemBuilder: (context, index) {
                    final shelf = shelves[index];
                    final shelfId = shelf['id'] as int;
                    final name = shelf['name'] as String;
                    final bookCount = shelf['book_count'] as int;
                    return ListTile(
                      selected: shelfId == selectedId,
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('$bookCount books'),
                      onTap: () => setState(() {
                        _selectedShelfId = shelfId;
                        if (!wide) _showShelfDetail = true;
                      }),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Shelf actions',
                        onSelected: (action) {
                          if (action == 'rename') {
                            _renameShelf(appState, shelves, shelf);
                          } else if (action == 'delete') {
                            _deleteShelf(appState, shelfId);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem<String>(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildShelfDetail(
      AppState appState, List<Map<String, Object?>> shelves, int shelfId,
      {required bool narrow}) {
    final theme = Theme.of(context);
    final index = shelves.indexWhere((s) => s['id'] == shelfId);
    final name = index >= 0 ? shelves[index]['name'] as String : '';
    final books = appState.library
        .shelfBooks(shelfId, includeHidden: appState.showHidden);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              if (narrow)
                IconButton(
                  tooltip: 'Back',
                  onPressed: () => setState(() => _showShelfDetail = false),
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _addBooks(appState, shelfId),
                icon: const Icon(Icons.add),
                label: const Text('Add books…'),
              ),
            ],
          ),
        ),
        Expanded(
          child: books.isEmpty
              ? const Center(child: Text('No books on this shelf'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    childAspectRatio: 2 / 3,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    return Builder(
                      builder: (cardContext) => BookCard(
                        book: book,
                        onTap: () => _openBook(book),
                        onLongPress: () =>
                            _showBookMenu(appState, cardContext, shelfId, book),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Dialog that prompts for a shelf name and validates it against [existingNames].
class _ShelfNameDialog extends StatefulWidget {
  const _ShelfNameDialog({
    required this.title,
    required this.actionLabel,
    required this.existingNames,
    required this.onInvalid,
    this.initialName = '',
  });

  final String title;
  final String actionLabel;
  final Set<String> existingNames;
  final void Function(String message) onInvalid;
  final String initialName;

  @override
  State<_ShelfNameDialog> createState() => _ShelfNameDialogState();
}

class _ShelfNameDialogState extends State<_ShelfNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty || widget.existingNames.contains(name.toLowerCase())) {
      widget.onInvalid('A shelf with that name already exists');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

/// Searchable multi-select list of books that can be added to a shelf.
class _AddBooksDialog extends StatefulWidget {
  const _AddBooksDialog({required this.books});

  final List<Book> books;

  @override
  State<_AddBooksDialog> createState() => _AddBooksDialogState();
}

class _AddBooksDialogState extends State<_AddBooksDialog> {
  final TextEditingController _search = TextEditingController();
  final Set<int> _selected = <int>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Book> get _filtered {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.books;
    return widget.books.where((book) {
      if (book.title.toLowerCase().contains(query)) return true;
      return book.authors.any((a) => a.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final books = _filtered;
    return AlertDialog(
      title: const Text('Add books'),
      content: SizedBox(
        width: 480,
        height: 480,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search books…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: widget.books.isEmpty
                  ? const Center(child: Text('No books to add'))
                  : books.isEmpty
                      ? const Center(child: Text('No matching books'))
                      : ListView.builder(
                          itemCount: books.length,
                          itemBuilder: (context, index) {
                            final book = books[index];
                            final bookId = book.id!;
                            return CheckboxListTile(
                              value: _selected.contains(bookId),
                              onChanged: (checked) => setState(() {
                                if (checked == true) {
                                  _selected.add(bookId);
                                } else {
                                  _selected.remove(bookId);
                                }
                              }),
                              title: Text(
                                book.title.isEmpty ? 'Untitled' : book.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                book.authors.isEmpty
                                    ? 'Unknown author'
                                    : book.authors.join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              dense: true,
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
