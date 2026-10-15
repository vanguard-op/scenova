import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../screens/sign_in_controller.dart';
import '../services/app_services.dart';

/// Opens the sign-in sheet over the surface that asked for it
/// (`FEAT-013`; `docs/Scenova/screens/08-account.md` → "Signed out").
///
/// Resolves true once the reader holds an account, so the scope that opened the
/// sheet reloads what the account now holds; a reader who backs out resolves
/// false and nothing changes.
Future<bool> showSignInSheet(
  BuildContext context, {
  SignInController? controller,
}) async {
  final signedIn = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SignInSheet(controller: controller),
  );
  return signedIn ?? false;
}

/// The sign-in form: the reader's email and password
/// (`FEAT-013`, D-032).
///
/// Every state the flow has is covered: the empty form, a field the reader has
/// to correct, an attempt in flight, an attempt that did not go through, and an
/// offline device. The sheet grows with the keyboard and is scrollable, so a
/// short window never hides the action.
class SignInSheet extends StatefulWidget {
  const SignInSheet({super.key, this.controller});

  /// The controller to drive the form with.
  ///
  /// When it is not given the sheet builds one from the services in scope; a
  /// caller that passes one owns its disposal. The preview gallery drives one so
  /// the submitting and failure states can be looked at.
  final SignInController? controller;

  @override
  State<SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<SignInSheet> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  SignInController? _controller;
  bool _revealed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final injected = widget.controller;
    if (injected != null) {
      _controller = injected;
      injected.addListener(_onChanged);
      return;
    }
    final services = ScenovaScope.of(context);
    final controller = SignInController(
      session: services.accountSession,
      connectivity: services.connectivity,
    );
    _controller = controller;
    controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    if (widget.controller == null) _controller?.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// The reader is correcting what they typed, so the last attempt's messages
  /// come off the form.
  void _onEdited(String _) {
    _controller!.clearErrors();
  }

  Future<void> _submit() async {
    final controller = _controller!;
    if (controller.submitting) return;
    FocusScope.of(context).unfocus();
    final signedIn = await controller.submit(
      email: _email.text,
      password: _password.text,
    );
    // A back gesture can resolve the sheet while the attempt is in flight; the
    // attempt itself is harmless and the reader is left where they are.
    if (!mounted || !signedIn) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final tokens = ScenovaTokens.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.lg,
            0,
            tokens.spacing.lg,
            tokens.spacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _content(context, controller),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, SignInController controller) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final submitting = controller.submitting;
    final offline = !controller.connectivity.isOnline;

    return <Widget>[
      Semantics(
        header: true,
        child: Text(
          'Sign in',
          style: styles.h3.copyWith(color: colors.textPrimary),
        ),
      ),
      SizedBox(height: tokens.spacing.xs),
      Text(
        'Your plan and your lookups follow your account to any device.',
        style: styles.bodySmall.copyWith(color: colors.textSecondary),
      ),
      if (offline && controller.formError == null) ...<Widget>[
        SizedBox(height: tokens.spacing.md),
        // The banner says the device is offline before the reader types; once
        // an attempt has been answered, its own message stands in its place, so
        // the same thing is never said twice.
        const OfflineBanner(
          message: 'You are offline. Sign in when you are back online.',
        ),
      ],
      if (controller.formError != null) ...<Widget>[
        SizedBox(height: tokens.spacing.md),
        _FormNotice(message: controller.formError!),
      ],
      SizedBox(height: tokens.spacing.lg),
      TextField(
        controller: _email,
        enabled: !submitting,
        autofocus: true,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        autofillHints: const <String>[AutofillHints.email],
        autocorrect: false,
        onChanged: _onEdited,
        decoration: InputDecoration(
          hintText: 'Email address',
          prefixIcon: AppIconView(
            icon: AppIcons.account,
            size: tokens.sizing.iconMd,
            color: colors.iconDefault,
          ),
          errorText: controller.emailError,
        ),
      ),
      SizedBox(height: tokens.spacing.md),
      TextField(
        controller: _password,
        enabled: !submitting,
        obscureText: !_revealed,
        textInputAction: TextInputAction.done,
        autofillHints: const <String>[AutofillHints.password],
        autocorrect: false,
        enableSuggestions: false,
        onChanged: _onEdited,
        onSubmitted: (_) => unawaited(_submit()),
        decoration: InputDecoration(
          hintText: 'Password',
          errorText: controller.passwordError,
          suffixIcon: ScenovaIconButton(
            icon: AppIcons.seeIt,
            tooltip: _revealed ? 'Hide password' : 'Show password',
            active: _revealed,
            onPressed: submitting
                ? null
                : () => setState(() => _revealed = !_revealed),
          ),
        ),
      ),
      SizedBox(height: tokens.spacing.lg),
      ScenovaButton(
        label: 'Sign in',
        expanded: true,
        isSubmitting: submitting,
        onPressed: submitting ? null : () => unawaited(_submit()),
      ),
      SizedBox(height: tokens.spacing.sm),
      ScenovaButton(
        label: 'Not now',
        variant: ScenovaButtonVariant.ghost,
        expanded: true,
        onPressed: submitting ? null : () => Navigator.of(context).pop(false),
      ),
    ];
  }
}

/// The message shown when the attempt itself did not go through, in the error
/// family so it reads as something to act on.
class _FormNotice extends StatelessWidget {
  const _FormNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(tokens.spacing.md),
        decoration: BoxDecoration(
          color: colors.error.tint,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
          border: Border.all(color: colors.error.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AppIconView(
              icon: AppIcons.error,
              size: tokens.sizing.iconSm,
              color: colors.error.element,
            ),
            SizedBox(width: tokens.spacing.sm),
            Expanded(
              child: Text(
                message,
                style: styles.bodySmall.copyWith(color: colors.error.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
