import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';

/// Manual fallback picker for a worker or an order.
///
/// Extracted from the assignment screen so the recall and confirm flows can
/// reach the same list instead of each growing their own copy.
Future<Map<String, dynamic>?> showSearchablePicker(
  BuildContext context, {
  required String title,
  required String searchHint,
  required String emptyMessage,
  required List<Map<String, dynamic>> items,
  required String Function(Map<String, dynamic> item) itemTitle,
  required String Function(Map<String, dynamic> item) itemSubtitle,
  required String Function(Map<String, dynamic> item) searchableText,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(CaslaRadius.lg)),
    ),
    builder: (context) => _SearchablePickerSheet(
      title: title,
      searchHint: searchHint,
      emptyMessage: emptyMessage,
      items: items,
      itemTitle: itemTitle,
      itemSubtitle: itemSubtitle,
      searchableText: searchableText,
    ),
  );
}

class _SearchablePickerSheet extends StatefulWidget {
  final String title;
  final String searchHint;
  final String emptyMessage;
  final List<Map<String, dynamic>> items;
  final String Function(Map<String, dynamic> item) itemTitle;
  final String Function(Map<String, dynamic> item) itemSubtitle;
  final String Function(Map<String, dynamic> item) searchableText;

  const _SearchablePickerSheet({
    required this.title,
    required this.searchHint,
    required this.emptyMessage,
    required this.items,
    required this.itemTitle,
    required this.itemSubtitle,
    required this.searchableText,
  });

  @override
  State<_SearchablePickerSheet> createState() => _SearchablePickerSheetState();
}

class _SearchablePickerSheetState extends State<_SearchablePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.trim().toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? widget.items
        : widget.items
              .where(
                (item) => widget
                    .searchableText(item)
                    .toLowerCase()
                    .contains(normalizedQuery),
              )
              .toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: CaslaSpacing.md,
          top: CaslaSpacing.md,
          right: CaslaSpacing.md,
          bottom: CaslaSpacing.md + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: CaslaType.subtitle,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: CaslaSpacing.sm),
              TextField(
                controller: _searchController,
                autofocus: widget.items.length > 8,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Xóa nội dung tìm kiếm',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: CaslaSpacing.xs),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(CaslaSpacing.lg),
                          child: Text(
                            normalizedQuery.isEmpty
                                ? widget.emptyMessage
                                : 'Không tìm thấy kết quả phù hợp.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: CaslaType.body,
                              color: CaslaColors.muted,
                              height: 1.4,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          final subtitle = widget.itemSubtitle(item);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              widget.itemTitle(item),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: CaslaType.body,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: subtitle.isEmpty
                                ? null
                                : Text(
                                    subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: CaslaType.caption,
                                    ),
                                  ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.pop(context, item),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
