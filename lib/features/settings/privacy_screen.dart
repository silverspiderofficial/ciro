import 'package:flutter/material.dart';

import '../../l10n/strings.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('privacy'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('privacyBody')),
          const SizedBox(height: 12),
          for (final k in ['privacyHostHf', 'studioPrivacyHost', 'privacyHostGemini', 'privacyHostCustom'])
            ListTile(leading: const Icon(Icons.lan_outlined), title: Text(s.t(k))),
        ],
      ),
    );
  }
}
