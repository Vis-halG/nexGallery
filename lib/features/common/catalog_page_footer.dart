import 'package:flutter/material.dart';

import '../../src/gallery_model.dart';

/// Explicit paging keeps inactive tabs from fetching the whole library.
class CatalogPageFooter extends StatelessWidget {
  const CatalogPageFooter({required this.model, super.key});

  final GalleryModel model;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text('${model.items.length} of ${model.totalItemCount} items'),
          if (model.hasMoreItems) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: model.loadMoreItems,
              icon: const Icon(Icons.expand_more_rounded),
              label: const Text('Load more'),
            ),
          ],
        ],
      ),
    );
  }
}
