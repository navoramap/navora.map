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
  String? _authError;
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
Navora Map; harita ve konum özelliklerinin yanı sıra kullanıcıların sohbet etmesine, sohbet odaları oluşturmasına, emlak ilanları ve kayıp hayvan/sahiplendirme ilanları paylaşmasına, kayıtlı yerleri keşfetmesine ve yol bildirimleri oluşturmasına imkân tanır. Kullanıcılar ayrıca yer ve rota araması yapabilir, adres ve rotalarını kaydedebilir. Harita, konum, arama ve rota bilgileri üçüncü taraf hizmetlerden gelebilir; güncel olmayabilir veya hatalı olabilir.

4. Kullanıcı İçerikleri ve Yasaklı Kullanım
Sohbet, ilan, yorum, görsel ve diğer kullanıcı içeriklerinden bunları paylaşan kişi sorumludur. Hukuka aykırı veya başkalarının haklarını ihlal eden; tehdit, taciz, zorbalık, nefret söylemi ya da ayrımcılık içeren; şiddeti veya kendine zarar vermeyi teşvik eden; cinsel istismar veya çocukların güvenliğini tehlikeye atan; dolandırıcılık, spam ya da kötüye kullanım amacı taşıyan; fikri mülkiyet veya kişisel verileri ihlal eden içerikleri paylaşamazsınız. Başkalarına ait kişisel bilgileri, açık izin veya hukuki dayanak olmadan yayımlayamazsınız.

5. Şikâyet, İnceleme ve Yaptırımlar
Uygunsuz olduğunu düşündüğünüz kullanıcı içeriğini uygulama içindeki şikâyet araçlarıyla veya navora.map@gmail.com adresinden bildirebilirsiniz. Bildirimler incelenir; ihlal oluşturan içerik kaldırılabilir. İhlalin niteliğine ve tekrarına göre içerik kaldırma, özelliklere erişimi kısıtlama, hesabı geçici olarak askıya alma veya hesabı kalıcı olarak kapatma uygulanabilir. Ağır ya da tekrarlanan ihlallerde, yürürlükteki mevzuatın izin verdiği ölçüde önceden bildirim yapılmaksızın işlem uygulanabilir. Kanunen gerekli hâllerde ilgili bilgiler yetkili makamlarla paylaşılabilir.

6. Hizmetin Sınırlandırılması ve Hesap Kapatma
Sözleşmeye veya yürürlükteki mevzuata aykırı kullanım tespit edilirse hesabınız geçici olarak askıya alınabilir veya kalıcı olarak kapatılabilir; ihlalli içerikler hizmetten kaldırılabilir. Hesabınızı uygulamadaki hesap silme seçeneğiyle kapatabilirsiniz. Yasal yükümlülükler veya uyuşmazlıkların çözümü için tutulması gereken kayıtlar, ilgili mevzuatın gerektirdiği süre boyunca saklanabilir.

7. Fikri Mülkiyet
Uygulamanın yazılımı, tasarımı, adı ve içerikleri, kanunen izin verilen ölçüde Navora Map'e veya ilgili hak sahiplerine aittir. İzinsiz kopyalanamaz veya dağıtılamaz.

8. Değişiklikler ve İletişim
Hizmetlerde veya bu sözleşmede değişiklik yapılabilir. Önemli değişiklikler uygulama veya e-posta yoluyla bildirilebilir. Sorularınız için: navora.map@gmail.com.

Son güncelleme: 10.11.2026
''';

  static const String _privacyText = '''
Veri sorumlusu: İbrahim Can Özdemir. Adres: Konya, Meram, Sahibata Mahallesi, Esenlerli Sokak, No: 19. İletişim: navora.map@gmail.com.

Navora Map; hesap ve profil bilgilerini (ad, e-posta, telefon ve tercihlerin), konum ve rota bilgilerini (yalnızca ilgili özellikleri kullandığında), sohbet/ilan/rapor içeriklerini, eklediğin görselleri ve hizmet güvenliği için gerekli teknik kayıtları işler. Bu bilgiler hesabını ve uygulama özelliklerini sağlamak, kullanıcı içeriklerini göstermek, şikâyetleri incelemek, kötüye kullanımı önlemek, hizmeti güvenli tutmak ve yasal yükümlülükleri yerine getirmek için kullanılır. E-posta kampanya tercihi isteğe bağlıdır.

Hesap ve uygulama altyapısı için Firebase; harita, yer ve rota özellikleri için Google Maps Platform; bazı yer aramaları için OpenStreetMap/Nominatim; yapay zekâ yanıtları için Firebase AI; çökme tanılama için Firebase Crashlytics kullanılır. Google veya Apple ile giriş yaparsan ilgili kimlik doğrulama sağlayıcısı da sürece katılır. Sesli arama işletim sisteminin konuşma tanıma hizmetini kullanabilir. Bu hizmetlere gönderilen veriler ilgili sağlayıcıların kendi gizlilik koşullarına tabidir; hizmet altyapısına bağlı olarak veriler Türkiye dışında işlenebilir.

Konum arka planda sürekli izlenmez; konum, konum izni ve ilgili özellik kullanımın kapsamında işlenir. Genel sohbet mesajları 30 gün, şifreli oda verileri 24 saat; sürüş ve tamamlanmış rota geçmişi en fazla 30 gün saklanacak şekilde temizleme işlemine alınır. İlan ve profil içerikleri sen silene, hesap silme işlemi tamamlanana veya içerik moderasyon kapsamında kaldırılana kadar saklanabilir. Hesap silme isteğini uygulamadaki “Hesabımı sil” seçeneğinden başlatabilirsin. Yasal yükümlülükler, güvenlik kayıtları ve yedekleme döngüleri nedeniyle bazı veriler gerekli süre boyunca kalabilir.

KVKK kapsamındaki kişisel veri taleplerin için navora.map@gmail.com adresine veya yukarıdaki adrese başvurabilirsin. Ayrıntılı bilgiye kamuya açık gizlilik politikamızdan ulaşabilirsin:
https://navoramapa.web.app/gizlilik-politikasi

Son güncelleme: 10.11.2026
''';

  static const String _publicPrivacyPolicyUrl =
      'https://navoramapa.web.app/gizlilik-politikasi';

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
              ? (currentUser.email?.split('@').first ?? 'Kullanıcı')
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
      _setAuthError('Lütfen e-posta adresinizi ve şifrenizi girin.');
      return;
    }

    if (_isSignUpMode && _nameController.text.trim().isEmpty) {
      _setAuthError('Lütfen adınızı girin.');
      return;
    }

    if (_isSignUpMode) {
      final passwordError = _passwordValidationError(password);
      if (passwordError != null) {
        _setAuthError(passwordError);
        return;
      }
    }

    if (_isSignUpMode && _phoneController.text.trim().isEmpty) {
      _setAuthError('Lütfen telefon numaranızı girin.');
      return;
    }

    if (_isSignUpMode && _genderPreference == null) {
      _setAuthError('Lütfen bir tercih seçin.');
      return;
    }

    if (_isSignUpMode && password != _confirmPasswordController.text.trim()) {
      _setAuthError('Şifreler eşleşmiyor.');
      return;
    }

    if (_isSignUpMode && (!_termsAccepted || !_privacyAccepted)) {
      _setAuthError(
        'Kayıt olmak için kullanıcı sözleşmesini ve KVKK metnini onaylayın.',
      );
      return;
    }

    setState(() {
      _isAuthLoading = true;
      _authError = null;
    });

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
            : (user.email?.split('@').first ?? 'Kullanıcı');
        _currentUserEmail = user.email ?? email;
        _isLoggedIn = true;
      });
    } on FirebaseAuthException catch (error) {
      debugPrint('E-posta kimlik doğrulaması başarısız: ${error.code}');
      if (!_isSignUpMode &&
          (error.code == 'wrong-password' ||
              error.code == 'invalid-credential' ||
              error.code == 'user-not-found')) {
        setState(() {
          _authError = 'E-posta veya şifre hatalı. Bilgilerinizi kontrol edin.';
        });
        return;
      }

      final message = switch (error.code) {
        'email-already-in-use' =>
          'Bu e-posta ile kayıtlı bir kullanıcı zaten var.',
        'invalid-email' => 'Geçerli bir e-posta adresi girin.',
        'wrong-password' ||
        'invalid-credential' ||
        'user-not-found' => 'E-posta veya şifre hatalı.',
        'weak-password' =>
          'Şifre en az 10 karakter olmalı; küçük ve büyük harf içermeli.',
        'operation-not-allowed' =>
          'E-posta ve şifre ile giriş Firebase projesinde etkin değil.',
        'user-disabled' => 'Bu hesap devre dışı bırakılmış.',
        'too-many-requests' =>
          'Çok fazla deneme yapıldı. Bir süre bekleyip tekrar deneyin.',
        'network-request-failed' =>
          'Bağlantı kurulamadı. İnternet bağlantınızı kontrol edin.',
        'invalid-api-key' ||
        'app-not-authorized' ||
        'configuration-not-found' =>
          'Uygulamanın Firebase yapılandırması doğrulanamadı.',
        _ =>
          'İşlem tamamlanamadı (Firebase: ${error.code}). Lütfen tekrar deneyin.',
      };
      _setAuthError(message);
    } on FirebaseException catch (error) {
      debugPrint('Kimlik doğrulama verisi kaydedilemedi: ${error.code}');
      final message = switch (error.code) {
        'permission-denied' => 'Hesabınız oluşturuldu ancak profil bilgileri kaydedilemedi. Uygulamayı kapatıp açarak devam edin.',
        'unavailable' || 'deadline-exceeded' => 'Bağlantı kurulamadı. İnternet bağlantınızı kontrol edip tekrar deneyin.',
        _ =>
          'Profil bilgileri kaydedilemedi (${error.code}). Lütfen tekrar deneyin.',
      };
      _setAuthError(message);
    } finally {
      if (mounted) {
        setState(() => _isAuthLoading = false);
      }
    }
  }

  void _setAuthError(String message) {
    if (!mounted) return;
    setState(() => _authError = message);
  }

  void _clearAuthError() {
    if (_authError == null) return;
    setState(() => _authError = null);
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

  Future<void> _openPublicPrivacyPolicy() async {
    final opened = await launchUrl(
      Uri.parse(_publicPrivacyPolicyUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      _showSnackBar('Gizlilik politikası açılamadı. Lütfen tekrar deneyin.');
    }
  }

  void _validateEmail(String value) {
    final email = value.trim();
    setState(() {
      _authError = null;
      _emailError = email.isEmpty || !email.contains('@')
          ? 'Geçerli bir e-posta adresi girin.'
          : null;
    });
  }

  void _validatePassword(String value) {
    setState(() {
      _authError = null;
      _passwordError = _isSignUpMode ? _passwordValidationError(value) : null;
    });
  }

  String? _passwordValidationError(String password) {
    if (password.isEmpty) return null;
    if (password.length < 10) return 'Şifre en az 10 karakter olmalı.';
    if (!RegExp(r'[a-z]').hasMatch(password)) {
      return 'Şifre en az bir küçük harf içermeli.';
    }
    if (!RegExp(r'[A-Z]').hasMatch(password)) {
      return 'Şifre en az bir büyük harf içermeli.';
    }
    return null;
  }

  String get _passwordStrength {
    final password = _passwordController.text;
    final completedRules = [
      password.length >= 10,
      RegExp(r'[a-z]').hasMatch(password),
      RegExp(r'[A-Z]').hasMatch(password),
    ].where((isMet) => isMet).length;
    if (completedRules == 3) return 'Güçlü';
    if (completedRules == 0) return 'Zayıf';
    return 'Gelişiyor';
  }

  Widget _buildPasswordStrengthIndicator() {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final password = _passwordController.text;
    final requirements = [
      ('10+ karakter', password.length >= 10),
      ('Küçük harf', RegExp(r'[a-z]').hasMatch(password)),
      ('Büyük harf', RegExp(r'[A-Z]').hasMatch(password)),
    ];
    final completedRules = requirements.where((rule) => rule.$2).length;
    final strengthColor = switch (completedRules) {
      0 => colors.error,
      1 => colors.error,
      2 => colors.primary,
      _ => const Color(0xFF4CAF50),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: strengthColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Şifre gücü: $_passwordStrength',
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: strengthColor,
                  ),
                ),
              ),
              Text(
                '$completedRules/3',
                style: textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: List.generate(3, (index) {
              return Expanded(
                child: Container(
                  height: 4,
                  margin: EdgeInsets.only(right: index == 2 ? 0 : 6),
                  decoration: BoxDecoration(
                    color: index < completedRules
                        ? strengthColor
                        : colors.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: requirements.map((requirement) {
              final isMet = requirement.$2;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isMet ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 15,
                    color: isMet ? const Color(0xFF4CAF50) : colors.outline,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    requirement.$1,
                    style: textTheme.labelSmall?.copyWith(
                      color: isMet ? colors.onSurface : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSocialAuth(String provider) async {
    setState(() => _isAuthLoading = true);

    try {
      final UserCredential credential;

      if (provider == 'Google') {
        final googleSignIn = GoogleSignIn.instance;
        await googleSignIn.initialize(
          clientId: '348191564859-5midietfkrqldc6l8f1r9vv30o4q89rh.apps.googleusercontent.com',
          serverClientId: '348191564859-m4ocm1b28056eshf92p0pib6oalr6m29.apps.googleusercontent.com',
        );

        final googleUser = await googleSignIn.authenticate();
        final idToken = googleUser.authentication.idToken;
        if (idToken == null) throw StateError('Google ID token alinamadi.');

        credential = await FirebaseAuth.instance.signInWithCredential(
          GoogleAuthProvider.credential(idToken: idToken),
        );
      } else {
        if (defaultTargetPlatform == TargetPlatform.android || kIsWeb) {
          _showSnackBar(
            'Android ve web için Apple girişinin kullanılabilmesi adına Apple Service ID ve yönlendirme adresi yapılandırılmalı.',
          );
          return;
        }

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
        'display_name': user.displayName ?? '$provider Kullanıcısı',
        'email': user.email,
        'provider': provider,
        'photo_url': user.photoURL,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        _currentUserName = user.displayName ?? '$provider Kullanıcısı';
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
      _showSnackBar('Giriş iptal edildi veya tamamlanamadı.');
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
      _currentUserName = 'Misafir Kullanıcı';
      _currentUserEmail = 'misafir@navora.app';
      _isLoggedIn = true;
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    AppNotificationService.show(message);
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingSession) {
      return const Scaffold(
        body: NavoraLoadingScreen(
          title: 'Navora hazırlanıyor',
          subtitle: 'Sana özel harita deneyimi yükleniyor.',
        ),
      );
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
          setState(() {
            _isSignUpMode = signupMode;
            _authError = null;
            _passwordError = signupMode
                ? _passwordValidationError(_passwordController.text)
                : null;
          });
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

  Widget _buildConsentCard({
    required bool value,
    required ValueChanged<bool?> onChanged,
    required String title,
    required String actionLabel,
    required VoidCallback onView,
    String? externalActionLabel,
    VoidCallback? onExternalView,
  }) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: value ? colors.primary.withValues(alpha: 0.6) : colors.outline,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(value: value, onChanged: onChanged),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(
                left: 2,
                top: 12,
                right: 12,
                bottom: 8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 0,
                    children: [
                      TextButton.icon(
                        onPressed: onView,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 34),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.description_outlined, size: 16),
                        label: Text(actionLabel),
                      ),
                      if (externalActionLabel != null && onExternalView != null)
                        TextButton.icon(
                          onPressed: onExternalView,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 34),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 15),
                          label: Text(externalActionLabel),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthScreen() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textTheme = theme.textTheme;
    final showAppleButton =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;

    return Scaffold(
      backgroundColor: colors.surfaceContainerLowest,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colors.surfaceContainerLowest,
              colors.surface,
              colors.surfaceContainerLowest,
            ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: -110,
                left: -100,
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primary.withValues(alpha: 0.08),
                  ),
                ),
              ),
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
                    horizontal: 28,
                    vertical: 56,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: colors.primary.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Icon(
                            Icons.explore_rounded,
                            size: 40,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'NAVORA MAP',
                          style: textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colors.primary,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isSignUpMode
                              ? 'Yolculuğuna hemen başla'
                              : 'Hesabına güvenle giriş yap',
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildAuthModeButton('Giriş Yap', false),
                              ),
                              Expanded(
                                child: _buildAuthModeButton('Kayıt Ol', true),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        if (_isSignUpMode) ...[
                          TextField(
                            controller: _nameController,
                            onChanged: (_) => _clearAuthError(),
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
                            labelText: 'E-posta adresi',
                            prefixIcon: const Icon(Icons.email_outlined),
                            errorText: _emailError,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (_isSignUpMode) ...[
                          TextField(
                            controller: _phoneController,
                            onChanged: (_) => _clearAuthError(),
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: 'Telefon numarası',
                              prefixIcon: const Icon(Icons.phone_outlined),
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (_isSignUpMode) ...[
                          PopupMenuButton<String>(
                            position: PopupMenuPosition.under,
                            color: colors.surface,
                            onSelected: (value) => setState(() {
                              _genderPreference = value;
                              _authError = null;
                            }),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'Kadın',
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
                            labelText: 'Şifre',
                            helperText: _isSignUpMode
                                ? 'En az 10 karakter; küçük ve büyük harf içermeli'
                                : null,
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
                          const SizedBox(height: 10),
                          _buildPasswordStrengthIndicator(),
                        ],
                        if (_isSignUpMode) ...[
                          const SizedBox(height: 14),
                          TextField(
                            controller: _confirmPasswordController,
                            obscureText: _obscureConfirmPassword,
                            onChanged: (_) => _clearAuthError(),
                            decoration: InputDecoration(
                              labelText: 'Şifre tekrar',
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
                          _buildConsentCard(
                            value: _termsAccepted,
                            onChanged: (value) => setState(() {
                              _termsAccepted = value ?? false;
                              _authError = null;
                            }),
                            title: 'Kullanıcı Sözleşmesi\'ni kabul ediyorum *',
                            actionLabel: 'Sözleşmeyi incele',
                            onView: () => _showLegalDocument(
                              'Kullanıcı Sözleşmesi',
                              _termsText,
                            ),
                          ),
                          _buildConsentCard(
                            value: _privacyAccepted,
                            onChanged: (value) => setState(() {
                              _privacyAccepted = value ?? false;
                              _authError = null;
                            }),
                            title: 'KVKK Açık Rıza Metni\'ni kabul ediyorum *',
                            actionLabel: 'KVKK metnini incele',
                            onView: () => _showLegalDocument(
                              'KVKK Açık Rıza Metni',
                              _privacyText,
                            ),
                            externalActionLabel: 'Web politikasını aç',
                            onExternalView: () =>
                                unawaited(_openPublicPrivacyPolicy()),
                          ),
                          CheckboxListTile(
                            value: _emailMarketingAccepted,
                            onChanged: (value) => setState(() {
                              _emailMarketingAccepted = value ?? false;
                              _authError = null;
                            }),
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
                                    : 'Şifremi unuttum',
                              ),
                            ),
                          ),
                        if (_authError != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: colors.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: colors.error.withValues(alpha: 0.45),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.error_outline_rounded,
                                  size: 18,
                                  color: colors.error,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _authError!,
                                    textAlign: TextAlign.center,
                                    style: textTheme.bodySmall?.copyWith(
                                      color: colors.error,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
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
                                    _isSignUpMode ? 'Kayıt Ol' : 'Giriş Yap',
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
                                'veya şununla devam et',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: OutlinedButton.icon(
                            onPressed: _isAuthLoading
                                ? null
                                : () => _handleSocialAuth('Google'),
                            icon: SvgPicture.asset(
                              'assets/logo/google_g.svg',
                              width: 22,
                              height: 22,
                            ),
                            label: const Text('Google ile devam et'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (showAppleButton) ...[
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: OutlinedButton.icon(
                              onPressed: _isAuthLoading
                                  ? null
                                  : () => _handleSocialAuth('Apple'),
                              icon: const Icon(Icons.apple, size: 22),
                              label: const Text('Apple ile devam et'),
                            ),
                          ),
                        ],
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
