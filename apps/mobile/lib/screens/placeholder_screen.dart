import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

/// A destination named on the navigation map whose own screen belongs to a
/// later phase.
///
/// The entry points exist so the map is wired and honest; the screen itself is
/// not designed here.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: EmptyState(icon: AppIcons.reading, headline: title, body: message),
    );
  }
}
