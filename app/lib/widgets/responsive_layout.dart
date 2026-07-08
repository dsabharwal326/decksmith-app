import 'package:flutter/material.dart';

class ResponsiveLayout extends StatelessWidget {
  final Widget sidebar;
  final Widget body;
  const ResponsiveLayout({super.key, required this.sidebar, required this.body});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 600) {
      return Row(
        children: [
          SizedBox(width: 200, child: sidebar),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      );
    }
    return body;
  }
}
