import 'package:flutter/material.dart';

import '../services/operator_auth.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/app_icons.dart';
import '../widgets/brand_mark.dart';
import '../widgets/scenova_button.dart';

/// The console's sign-in: the identity-provider surface an operator lands on
/// when there is no session, and where the console redirects when a session
/// ends (`docs/Scenova/screens/09-review-queue.md` → Unauthenticated).
///
/// The account is an operator's, carrying the `curator` role and enrolled in a
/// second factor. A password sign-in that the provider holds for a second
/// factor moves the screen to the code step; the role itself is checked at the
/// gateway, so an account without it signs in here and is refused at the queue.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final OperatorAuth auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

enum _Stage { credentials, secondFactor }

class _SignInScreenState extends State<SignInScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();

  _Stage _stage = _Stage.credentials;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submitCredentials() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final outcome = await widget.auth.signIn(
        email: _email.text,
        password: _password.text,
      );
      if (!mounted) return;
      if (outcome is SecondFactorRequired) {
        setState(() {
          _stage = _Stage.secondFactor;
          _submitting = false;
        });
      }
      // A completed sign-in needs no further step: the console gate reacts to
      // the session and shows the queue.
    } on OperatorAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _submitting = false;
      });
    }
  }

  Future<void> _submitSecondFactor() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.auth.submitSecondFactor(_code.text);
      // On success the console gate shows the queue.
    } on OperatorAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _submitting = false;
      });
    }
  }

  void _backToCredentials() {
    widget.auth.cancelSecondFactor();
    setState(() {
      _stage = _Stage.credentials;
      _code.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Scaffold(
      backgroundColor: colors.surface,
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(tokens.spacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: EdgeInsets.all(tokens.spacing.xl),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(ScenovaRadius.lg),
                border: Border.all(color: colors.border),
                boxShadow: tokens.shadowMd,
              ),
              child: _stage == _Stage.credentials
                  ? _credentialsForm(context)
                  : _secondFactorForm(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _credentialsForm(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Heading(
          title: 'Review console',
          subtitle: 'Sign in with your curator account.',
        ),
        SizedBox(height: tokens.spacing.xl),
        TextField(
          controller: _email,
          enabled: !_submitting,
          autofillHints: const <String>[AutofillHints.username],
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          style: styles.body.copyWith(color: colors.textPrimary),
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
          ),
        ),
        SizedBox(height: tokens.spacing.md),
        TextField(
          controller: _password,
          enabled: !_submitting,
          obscureText: true,
          autofillHints: const <String>[AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitCredentials(),
          style: styles.body.copyWith(color: colors.textPrimary),
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        if (_error != null) ...<Widget>[
          SizedBox(height: tokens.spacing.md),
          _ErrorText(message: _error!),
        ],
        SizedBox(height: tokens.spacing.lg),
        ScenovaButton(
          label: 'Sign in',
          expanded: true,
          isSubmitting: _submitting,
          onPressed: _submitting ? null : _submitCredentials,
        ),
      ],
    );
  }

  Widget _secondFactorForm(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Heading(
          title: 'Enter your code',
          subtitle: 'Open your authenticator app and enter the six-digit code.',
        ),
        SizedBox(height: tokens.spacing.xl),
        TextField(
          controller: _code,
          enabled: !_submitting,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitSecondFactor(),
          style: styles.body.copyWith(color: colors.textPrimary),
          decoration: const InputDecoration(
            labelText: 'Code',
            hintText: '123456',
          ),
        ),
        if (_error != null) ...<Widget>[
          SizedBox(height: tokens.spacing.md),
          _ErrorText(message: _error!),
        ],
        SizedBox(height: tokens.spacing.lg),
        ScenovaButton(
          label: 'Verify',
          expanded: true,
          isSubmitting: _submitting,
          onPressed: _submitting ? null : _submitSecondFactor,
        ),
        SizedBox(height: tokens.spacing.sm),
        ScenovaButton(
          label: 'Use a different account',
          variant: ScenovaButtonVariant.ghost,
          expanded: true,
          onPressed: _submitting ? null : _backToCredentials,
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            BrandMark(size: tokens.sizing.iconLg, semanticLabel: 'Scenova'),
            SizedBox(width: tokens.spacing.sm),
            Text(
              'Scenova',
              style: styles.h2.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
        SizedBox(height: tokens.spacing.lg),
        Text(title, style: styles.h1.copyWith(color: colors.textPrimary)),
        SizedBox(height: tokens.spacing.xs),
        Text(
          subtitle,
          style: styles.body.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Row(
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
    );
  }
}
