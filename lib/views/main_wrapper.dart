part of '../main.dart';

class MainWrapper extends StatefulWidget {
  const MainWrapper({super.key});

  @override
  State<MainWrapper> createState() => _MainWrapperState();
}

class _MainWrapperState extends State<MainWrapper> {
  bool _isLoggedIn = false;
  bool _isSignUpMode = false;
  bool _isAuthLoading = false;
  bool _isCheckingSession = true;
  int _resetCooldownSeconds = 0;
  Timer? _resetCooldownTimer;
  bool _termsAccepted = false;
  bool _privacyAccepted = false;
  bool _emailMarketingAccepted = false;
  String? _genderPreference;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _emailError;
  String? _passwordError;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  String _currentUserName = 'Misafir Kullanıcı';
  String _currentUserEmail = 'misafir@navora.app';

  static const String _termsText = '''
1. Taraflar ve Kapsam
Bu Kullanıcı Sözleşmesi, Navora Map mobil uygulamasını kullanan kişi ile uygulamanın işletmecisi arasında düzenlenmiştir. Uygulamayı kullanarak bu sözleşmeyi kabul etmiş olursunuz.

2. Hesap Kullanımı
Kayıt sırasında verdiğiniz bilgilerin doğru ve güncel olması gerekir. Hesabınızın güvenliğinden siz sorumlusunuz. Hesabınızı başka bir kişiye devredemez veya başkasının hesabını kullanamazsınız.

3. Uygulama Hizmetleri
Navora Map; harita, rota, konum, kayıtlı adresler, sohbet ve sürüş destek özellikleri sunar. Harita ve trafik bilgileri gecikeli olabilir veya hatalı olabilir. Uygulama, sürüş sırasında dikkatinizin yerine geçmez; trafik kurallarına ve güvenli sürüş ilkelerine uymalısınız.

4. Kullanıcı Sorumlulukları
Uygulamayı hukuka aykırı, başkalarını rahatsız edecek, tehdit içeren veya yanıltıcı içerik paylaşacak şekilde kullanamazsınız. Başkalarının kişisel verilerini izinsiz paylaşmamalısınız.

5. Hesabın Askıya Alınması
Sözleşmeye veya yürürlükteki mevzuata aykırı kullanım tespit edilirse hesabınız geçici olarak askıya alınabilir ya da kapatılabilir.

6. Fikri Mülkiyet
Uygulamanın yazılımı, tasarımı, adı ve içerikleri, kanunen izin verilen ölçüde Navora Map'e veya ilgili hak sahiplerine aittir. İzinsiz kopyalanamaz veya dağıtılamaz.

7. Değişiklikler ve İletişim
Hizmetlerde veya bu sözleşmede değişiklik yapilabilir. Önemli değişiklikler uygulama veya e-posta yoluyla bildirilebilir. Sorularınız için: destek@navoramap.com.

Son güncelleme: 03.09.2026
''';

  static const String _privacyText = '''
1. Veri Sorumlusu
Kişisel verileriniz, Navora Map hizmetinin işletmecisi olan Navora Map tarafından veri sorumlusu sıfatıyla işlenir. İletişim: Navora Map - destek@navoramap.com.

2. İşlenen Veriler
Hesap oluştururken ad soyad, e-posta adresi ve telefon numarası; uygulamayı kullanırken ise tercihleriniz, kayıtlı adresleriniz, rota ve sürüş verileriniz işlenebilir.

3. İşleme Amaçları
Verileriniz; hesap oluşturma ve doğrulama, profil yönetimi, uygulama hizmetlerinin sunulması, güvenliğin sağlanması, destek taleplerinin yanıtlanması ve yasal yükümlülüklerin yerine getirilmesi amaçlarıyla işlenir.

4. Hukuki Sebep
Kişisel verileriniz, sözleşmenin kurulması ve ifası, hukuki yükümlülüklerin yerine getirilmesi, meşru menfaat ve gerekli olduğu durumlarda açık rıza hukuki sebeplerine dayanılarak işlenir.

5. Aktarım ve Saklama
Verileriniz, hizmetin sunulması için kullanılan güvenli altyapı ve teknoloji hizmet sağlayıcılarına, yalnızca gerekli ölçüde aktarılabilir. Veriler, işleme amacı için gerekli süre boyunca ve yasal saklama sürelerine uygun olarak saklanır.

6. Haklarınız
KVKK'nin 11. maddesi kapsamındaki haklarınız için destek@navoramap.com üzerinden başvurabilirsiniz. Başvurunuzda kimliğinizi doğrulamaya yarayacak bilgileri ve talebinizi açıkça belirtmeniz gerekir.

7. Açık Rıza
Açık rıza verdiğiniz durumlarda bu rızayı her zaman geri çekebilirsiniz. Rızanın geri çekilmesi, geri çekme tarihinden önceki işlemlerin hukuka uygunluğunu etkilemez.

Son güncelleme: 03.09.2026
''';

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _resetCooldownTimer?.cancel();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      var profileName = currentUser.displayName ?? '';
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .get();
        final savedName = snapshot.data()?['display_name'];
        if (savedName is String && savedName.trim().isNotEmpty) {
          profileName = savedName.trim();
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _currentUserName = profileName.isEmpty
              ? (currentUser.email?.split('@').first ?? 'Kullanici')
              : profileName;
          _currentUserEmail = currentUser.email ?? '';
          _isLoggedIn = true;
        });
      }
    }

    if (mounted) {
      setState(() => _isCheckingSession = false);
    }
  }

  Future<void> _handleAuth() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showSnackBar('Lütfen tüm alanları doldurun.');
      return;
    }

    if (_isSignUpMode && _nameController.text.trim().isEmpty) {
      _showSnackBar('Lütfen adınızı girin.');
      return;
    }

    if (_isSignUpMode && _phoneController.text.trim().isEmpty) {
      _showSnackBar('Lütfen telefon numaranızı girin.');
      return;
    }

    if (_isSignUpMode && _genderPreference == null) {
      _showSnackBar('Lütfen bir tercih seçin.');
      return;
    }

    if (_isSignUpMode && password != _confirmPasswordController.text.trim()) {
      _showSnackBar('Sifreler eslesmiyor.');
      return;
    }

    if (_isSignUpMode && (!_termsAccepted || !_privacyAccepted)) {
      _showSnackBar('Kayıt olmak için zorunlu metinleri onaylayın.');
      return;
    }

    setState(() => _isAuthLoading = true);

    try {
      final credential = _isSignUpMode
          ? await FirebaseAuth.instance.createUserWithEmailAndPassword(
              email: email,
              password: password,
            )
          : await FirebaseAuth.instance.signInWithEmailAndPassword(
              email: email,
              password: password,
            );

      final user = credential.user;
      if (user == null) return;

      if (_isSignUpMode) {
        await user.updateDisplayName(_nameController.text.trim());
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'display_name': _nameController.text.trim(),
          'email': user.email,
          'phone': _phoneController.text.trim(),
          'gender_preference': _genderPreference,
          'terms_accepted': _termsAccepted,
          'privacy_accepted': _privacyAccepted,
          'email_marketing_accepted': _emailMarketingAccepted,
          'created_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      if (!mounted) return;

      setState(() {
        _currentUserName =
            (user.displayName ?? _nameController.text.trim()).isNotEmpty
            ? (user.displayName ?? _nameController.text.trim())
            : (user.email?.split('@').first ?? 'Kullanici');
        _currentUserEmail = user.email ?? email;
        _isLoggedIn = true;
      });
    } on FirebaseAuthException catch (error) {
      final message = switch (error.code) {
        'email-already-in-use' =>
          'Bu e-posta ile kayitli bir kullanici zaten var.',
        'invalid-email' => 'Geçerli bir e-posta adresi girin.',
        'wrong-password' ||
        'invalid-credential' ||
        'user-not-found' => 'E-posta veya şifre hatalı.',
        'weak-password' => 'Şifre en az 6 karakter olmalı.',
        _ => 'İşlem gerçekleştirilemedi. Lütfen tekrar deneyin.',
      };
      _showSnackBar(message);
    } finally {
      if (mounted) {
        setState(() => _isAuthLoading = false);
      }
    }
  }

  Future<void> _handlePasswordReset() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showSnackBar('Önce e-posta adresinizi girin.');
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      _showSnackBar(
        'Şifre sıfırlama bağlantısı e-posta adresinize gönderildi.',
      );
      _resetCooldownTimer?.cancel();
      setState(() => _resetCooldownSeconds = 60);

      _resetCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (_resetCooldownSeconds <= 1) {
          timer.cancel();
          setState(() => _resetCooldownSeconds = 0);
        } else {
          setState(() => _resetCooldownSeconds--);
        }
      });
    } on FirebaseAuthException catch (error) {
      final message = switch (error.code) {
        'invalid-email' => 'Geçerli bir e-posta adresi girin.',
        'user-not-found' => 'Bu e-posta ile kayıtlı kullanıcı bulunamadı.',
        _ => 'Şifre sıfırlama bağlantısı gönderilemedi.',
      };
      _showSnackBar(message);
    }
  }

  void _showLegalDocument(String title, String content) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(content)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  void _validateEmail(String value) {
    final email = value.trim();
    setState(() {
      _emailError = email.isEmpty || !email.contains('@')
          ? 'Geçerli bir e-posta adresi girin.'
          : null;
    });
  }

  void _validatePassword(String value) {
    setState(() {
      _passwordError = value.isNotEmpty && value.length < 6
          ? 'Sifre en az 6 karakter olmali.'
          : null;
    });
  }

  String get _passwordStrength {
    final password = _passwordController.text;
    if (password.length < 6) return 'Zayif';
    if (password.length < 10 ||
        !RegExp(r'[A-Z]').hasMatch(password) ||
        !RegExp(r'[0-9]').hasMatch(password)) {
      return 'Orta';
    }
    return 'Güçlü';
  }

  Future<void> _handleSocialAuth(String provider) async {
    setState(() => _isAuthLoading = true);

    try {
      final UserCredential credential;

      if (provider == 'Google') {
        final googleSignIn = GoogleSignIn.instance;
        await googleSignIn.initialize(
          serverClientId: '1034975486898-4e7he1dh0tu4kjmut9ji4eio6bfc4jdp.apps.googleusercontent.com',
        );

        final googleUser = await googleSignIn.authenticate();
        final idToken = googleUser.authentication.idToken;
        if (idToken == null) throw StateError('Google ID token alinamadi.');

        credential = await FirebaseAuth.instance.signInWithCredential(
          GoogleAuthProvider.credential(idToken: idToken),
        );
      } else {
        final rawNonce = generateNonce();
        final nonce = sha256.convert(utf8.encode(rawNonce)).toString();

        final appleCredential = await SignInWithApple.getAppleIDCredential(
          scopes: [
            AppleIDAuthorizationScopes.email,
            AppleIDAuthorizationScopes.fullName,
          ],
          nonce: nonce,
        );

        final idToken = appleCredential.identityToken;
        if (idToken == null) throw StateError('Apple ID token alinamadi.');

        credential = await FirebaseAuth.instance.signInWithCredential(
          OAuthProvider('apple.com')
              .credential(idToken: idToken, rawNonce: rawNonce),
        );
      }

      final user = credential.user;
      if (user == null) return;

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'display_name': user.displayName ?? '$provider Kullanicisi',
        'email': user.email,
        'provider': provider,
        'photo_url': user.photoURL,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        _currentUserName = user.displayName ?? '$provider Kullanicisi';
        _currentUserEmail = user.email ?? '';
        _isLoggedIn = true;
      });
    } on FirebaseAuthException catch (error) {
      _showSnackBar(switch (error.code) {
        'account-exists-with-different-credential' =>
          'Bu e-posta zaten kayıtlı. Mevcut giriş yöntemini kullanın.',
        'credential-already-in-use' => 'Bu hesap başka bir kullanıcıya bağlı.',
        _ => 'Giriş yapılamadı. Lütfen tekrar deneyin.',
      });
    } catch (_) {
      _showSnackBar('Giris iptal edildi veya tamamlanamadi.');
    } finally {
      if (mounted) {
        setState(() => _isAuthLoading = false);
      }
    }
  }

  Future<void> _handleLogout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;

    setState(() {
      _isLoggedIn = false;
      _termsAccepted = false;
      _privacyAccepted = false;
      _emailMarketingAccepted = false;
      _genderPreference = null;
      _nameController.clear();
      _emailController.clear();
      _phoneController.clear();
      _passwordController.clear();
      _confirmPasswordController.clear();
    });
  }

  Future<void> _continueAsGuest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auth_screen_seen', true);
    if (!mounted) return;

    setState(() {
      _currentUserName = 'Misafir Kullanici';
      _currentUserEmail = 'misafir@navora.app';
      _isLoggedIn = true;
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isLoggedIn) {
      return _buildAuthScreen();
    }

    return HomePage(
      userName: _currentUserName,
      userEmail: _currentUserEmail,
      onLogout: _handleLogout,
    );
  }

  Widget _buildAuthModeButton(String label, bool signupMode) {
    final selected = _isSignUpMode == signupMode;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return GestureDetector(
      onTap: () {
        if (_isSignUpMode != signupMode) {
          setState(() => _isSignUpMode = signupMode);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? colors.surfaceContainerHighest : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.18),
                    blurRadius: 5,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: selected ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildAuthScreen() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textTheme = theme.textTheme;
    final showAppleButton =
        Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;

    return Scaffold(
      body: Container(
        color: colors.surfaceContainerLowest,
        child: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    onPressed: _continueAsGuest,
                    icon: const Icon(Icons.close_rounded, size: 26),
                  ),
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: colors.outlineVariant),
                      boxShadow: [
                        BoxShadow(
                          color: colors.primary.withValues(alpha: 0.2),
                          blurRadius: 24,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.map_rounded,
                            size: 46,
                            color: colors.onPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'NAVORA MAP',
                          style: textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colors.primary,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildAuthModeButton('Giris Yap', false),
                              ),
                              Expanded(
                                child: _buildAuthModeButton('Kayit Ol', true),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _isSignUpMode
                              ? 'Yeni bir hesap olusturun'
                              : 'Hesabiniza giris yapin',
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        if (_isSignUpMode) ...[
                          TextField(
                            controller: _nameController,
                            decoration: InputDecoration(
                              labelText: 'Ad Soyad',
                              prefixIcon: const Icon(Icons.person_outline),
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          onChanged: _validateEmail,
                          decoration: InputDecoration(
                            labelText: 'E-Posta Adresi',
                            prefixIcon: const Icon(Icons.email_outlined),
                            errorText: _emailError,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (_isSignUpMode) ...[
                          TextField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: 'Telefon Numarasi',
                              prefixIcon: const Icon(Icons.phone_outlined),
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (_isSignUpMode) ...[
                          PopupMenuButton<String>(
                            position: PopupMenuPosition.under,
                            color: colors.surface,
                            onSelected: (value) =>
                                setState(() => _genderPreference = value),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'Kadin',
                                child: Text('Kadın'),
                              ),
                              PopupMenuItem(
                                value: 'Erkek',
                                child: Text('Erkek'),
                              ),
                              PopupMenuItem(
                                value: 'Belirtmek istemiyorum',
                                child: Text('Belirtmek istemiyorum'),
                              ),
                            ],
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 16,
                              ),
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: colors.outlineVariant,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.person_outline,
                                    color: colors.secondary,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Cinsiyet tercihi',
                                          style: textTheme.labelMedium
                                              ?.copyWith(
                                                color: colors.secondary,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _genderPreference ?? 'Seçiniz',
                                          style: textTheme.bodyMedium,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    Icons.arrow_drop_down,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        TextField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          onChanged: _validatePassword,
                          decoration: InputDecoration(
                            labelText: 'Sifre',
                            prefixIcon: const Icon(Icons.lock_outline),
                            errorText: _passwordError,
                            suffixIcon: IconButton(
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (_isSignUpMode &&
                            _passwordController.text.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Şifre gücü: $_passwordStrength',
                              style: textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _passwordStrength == 'Güçlü'
                                    ? colors.secondary
                                    : _passwordStrength == 'Orta'
                                    ? colors.primary
                                    : colors.error,
                              ),
                            ),
                          ),
                        ],
                        if (_isSignUpMode) ...[
                          const SizedBox(height: 14),
                          TextField(
                            controller: _confirmPasswordController,
                            obscureText: _obscureConfirmPassword,
                            decoration: InputDecoration(
                              labelText: 'Sifre Tekrar',
                              prefixIcon: const Icon(Icons.lock_reset_outlined),
                              suffixIcon: IconButton(
                                onPressed: () => setState(
                                  () => _obscureConfirmPassword =
                                      !_obscureConfirmPassword,
                                ),
                                icon: Icon(
                                  _obscureConfirmPassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          CheckboxListTile(
                            value: _termsAccepted,
                            onChanged: (value) =>
                                setState(() => _termsAccepted = value ?? false),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Kullanıcı Sözleşmesi\'ni kabul ediyorum *',
                                    style: textTheme.bodySmall,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _showLegalDocument(
                                    'Kullanıcı Sözleşmesi',
                                    _termsText,
                                  ),
                                  child: const Text('Metni oku'),
                                ),
                              ],
                            ),
                          ),
                          CheckboxListTile(
                            value: _privacyAccepted,
                            onChanged: (value) => setState(
                              () => _privacyAccepted = value ?? false,
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'KVKK Açık Rıza Metni\'ni kabul ediyorum *',
                                    style: textTheme.bodySmall,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _showLegalDocument(
                                    'KVKK Açık Rıza Metni',
                                    _privacyText,
                                  ),
                                  child: const Text('Metni oku'),
                                ),
                              ],
                            ),
                          ),
                          CheckboxListTile(
                            value: _emailMarketingAccepted,
                            onChanged: (value) => setState(
                              () => _emailMarketingAccepted = value ?? false,
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                              'E-posta ile kampanya ve bilgilendirme almak istiyorum',
                              style: textTheme.bodySmall,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        if (!_isSignUpMode)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _resetCooldownSeconds > 0
                                  ? null
                                  : _handlePasswordReset,
                              child: Text(
                                _resetCooldownSeconds > 0
                                    ? 'Tekrar gönder (${_resetCooldownSeconds}s)'
                                    : 'Şifremi Unuttum',
                              ),
                            ),
                          ),
                        if (!_isSignUpMode) const SizedBox(height: 4),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: _isAuthLoading ? null : _handleAuth,
                            child: _isAuthLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    _isSignUpMode ? 'Kayit Ol' : 'Giris Yap',
                                    style: textTheme.labelLarge,
                                  ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                'veya sununla devam et',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _handleSocialAuth('Google'),
                                icon: Icon(
                                  Icons.g_mobiledata_rounded,
                                  color: colors.primary,
                                ),
                                label: const Text('Google'),
                              ),
                            ),
                            if (showAppleButton) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _handleSocialAuth('Apple'),
                                  icon: const Icon(Icons.apple),
                                  label: const Text('Apple'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
