// lib/main.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

/// ANA URL’LER
const String kStartUrl = 'https://forms.kontinansdernegi.org/'; // sondaki / önemli
const String kWpMeEndpoint =
    'https://forms.kontinansdernegi.org/wp-json/custom/v1/user-profile';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KontinansFormsApp());
}

class KontinansFormsApp extends StatelessWidget {
  const KontinansFormsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sorgulama Formları',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E67A8)),
        useMaterial3: true,
      ),
      home: const IntroScreen(),
    );
  }
}

/// ----------------------
/// 1) INTRO (4 sn video)
/// ----------------------
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  late final VideoPlayerController _videoController;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _videoController = VideoPlayerController.asset('assets/intro.mp4');
    _videoController.initialize().then((_) {
      if (!mounted) return;
      _videoController.setLooping(false);
      _videoController.play();
      setState(() {});
      _timer = Timer(const Duration(seconds: 4), _goNext);
    });
  }

  void _goNext() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const WebShell()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: _videoController.value.isInitialized
            ? FittedBox(
          fit: BoxFit.cover, // Ekranı kaplasın (contain istersen değiştir)
          child: SizedBox(
            width: _videoController.value.size.width,
            height: _videoController.value.size.height,
            child: VideoPlayer(_videoController),
          ),
        )
            : const CircularProgressIndicator(),
      ),
    );
  }
}

/// ------------------------------------------------------
/// 2) Ana ekran: WebView + Bottom bar + Side panel (drawer)
/// ------------------------------------------------------
class WebShell extends StatefulWidget {
  const WebShell({super.key});

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final WebViewController _controller;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  final ValueNotifier<bool> _isOnline = ValueNotifier<bool>(true);

  // WebView içerik yüklerken hata alırsa (ATS, SSL, sunucu vs.)
  final ValueNotifier<bool> _hasWebError = ValueNotifier<bool>(false);

  Map<String, dynamic>? _user; // null => giriş yok / okunamadı
  final _cookieManager = WebviewCookieManager();

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _progress.value = 0;
            _hasWebError.value = false; // Yeni sayfa yüklenirken hata bayrağını sıfırla
          },
          onProgress: (p) => _progress.value = p / 100.0,
          onWebResourceError: (e) {
            // İnternet var ama WebView içerik yüklerken hata aldıysa buraya düşer
            _hasWebError.value = true;
          },
          onNavigationRequest: _handleNavigation,
          onPageFinished: (url) async {
            _progress.value = 1;
            // Sayfa yüklenince JS’ten kullanıcı bilgisi almaya çalış
            await _fetchUserFromJSOnce();
          },
        ),
      )
      ..loadRequest(Uri.parse(kStartUrl));

    Connectivity().onConnectivityChanged.listen((result) {
      final online = result != ConnectivityResult.none;
      _isOnline.value = online;
      if (online) _controller.reload();
    });
  }

  /// Dış şema ve dış domain linkleri sistemde aç
  NavigationDecision _handleNavigation(NavigationRequest req) {
    final uri = Uri.tryParse(req.url);
    if (uri == null) return NavigationDecision.navigate;
    final isSameHost = uri.host.endsWith('kontinansdernegi.org');

    if (!isSameHost ||
        uri.scheme == 'tel' ||
        uri.scheme == 'mailto' ||
        uri.scheme == 'whatsapp') {
      _launchExternal(req.url);
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  Future<void> _launchExternal(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _pullToRefresh() async {
    try {
      await _controller.reload();
      await Future.delayed(const Duration(milliseconds: 300));
      await _fetchUserFromJSOnce();
    } catch (_) {}
  }

  /// Drawer açılmadan hemen önce kullanıcıyı çekip aç
  Future<void> _openDrawer() async {
    await _fetchUserFromJSOnce(); // Önce JS
    if (_user == null) {
      await _fetchUserFromWP(); // JS yoksa REST fallback
    }
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /// JS ile tek seferlik kullanıcı datasını almaya çalış
  Future<void> _fetchUserFromJSOnce() async {
    if (!mounted) return;
    try {
      const js =
          'typeof window.userProfileData !== "undefined" && window.userProfileData ? JSON.stringify(window.userProfileData) : null';
      final result = await _controller.runJavaScriptReturningResult(js);

      if (result == null) return;

      String jsonString = result is String ? result : result.toString();
      if (jsonString.startsWith('"') && jsonString.endsWith('"')) {
        jsonString = jsonDecode(jsonString); // quoted string'i çöz
      }
      if (jsonString.toLowerCase() == 'null' || jsonString.trim().isEmpty) {
        return;
      }

      final Map<String, dynamic> map =
      Map<String, dynamic>.from(jsonDecode(jsonString));

      if (mounted) setState(() => _user = map);
    } catch (_) {
      // JS hazır değilse sessiz geç
    }
  }

  /// Fallback: Cookie + REST (custom/v1/user-profile)
  Future<void> _fetchUserFromWP() async {
    try {
      final cookies = await _cookieManager.getCookies(kStartUrl);
      final cookieHeader =
      cookies.map((c) => '${c.name}=${c.value}').join('; ');

      final resp = await http.get(
        Uri.parse(kWpMeEndpoint),
        headers: {
          'Cookie': cookieHeader,
          'Accept': 'application/json',
        },
      );

      if (resp.statusCode == 200 && resp.body.isNotEmpty) {
        final json = jsonDecode(resp.body);
        // {status:'success', data:{...}} yapısı
        if (json is Map &&
            json['status'] == 'success' &&
            json['data'] is Map<String, dynamic>) {
          if (mounted) {
            setState(() => _user =
            Map<String, dynamic>.from(json['data'] as Map<String, dynamic>));
          }
          return;
        }
        // Alternatif: direkt map dönen endpoint
        if (json is Map && json.containsKey('adsoyad')) {
          if (mounted) setState(() => _user = Map<String, dynamic>.from(json));
          return;
        }
      }

      if (mounted) setState(() => _user = null);
    } catch (_) {
      if (mounted) setState(() => _user = null);
    }
  }

  /// Oturumu kapat: çerezleri temizle, cache temizle, ana sayfaya dön
  Future<void> _logout() async {
    try {
      await _cookieManager.clearCookies();
      await _controller.clearCache();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _user = null);
    await _controller.loadRequest(Uri.parse(kStartUrl));
  }

  void _showKvkk() {
    showDialog(
      context: context,
      builder: (_) => const Dialog(
        insetPadding: EdgeInsets.all(16),
        child: _KvkkView(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('Kontinans Formlar'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
            tooltip: 'Yenile',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (_, p, __) {
              return p == 0 || p == 1
                  ? const SizedBox(height: 3)
                  : LinearProgressIndicator(value: p);
            },
          ),
        ),
      ),
      endDrawerEnableOpenDragGesture: false, // sadece hamburger ile
      endDrawer: _SidePanel(
        user: _user,
        onClose: () => Navigator.of(context).pop(),
        onShowKvkk: _showKvkk,
        onLogout: _logout,
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: _isOnline,
        builder: (_, online, __) {
          if (!online) {
            // Cihazda gerçekten internet yoksa
            return _OfflineView(onRetry: () async {
              final connectivity = await Connectivity().checkConnectivity();
              if (connectivity != ConnectivityResult.none) {
                _isOnline.value = true;
                _controller.reload();
              }
            });
          }

          // İnternet var ama WebView içerik yüklerken hata aldıysa (SSL, sunucu vs.)
          return ValueListenableBuilder<bool>(
            valueListenable: _hasWebError,
            builder: (_, hasError, __) {
              if (hasError) {
                return _WebErrorView(
                  onRetry: () {
                    _hasWebError.value = false;
                    _controller.reload();
                  },
                );
              }

              // Her şey normalse WebView'i göster
              return RefreshIndicator(
                onRefresh: _pullToRefresh,
                child: WebViewWidget(controller: _controller),
              );
            },
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: BottomAppBar(
          height: 56,
          child: Row(
            children: [
              const SizedBox(width: 12),
              const Text(
                'Kontinans Derneği Onam Formları',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: Image.asset('assets/images/icon_menu.png', height: 24),
                onPressed: _openDrawer,
                tooltip: 'Menü',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ------------------------------
/// Side panel (logo + çizgi + uyarı/profil + KVKK + logout)
/// ------------------------------
class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.user,
    required this.onClose,
    required this.onShowKvkk,
    required this.onLogout,
  });

  final Map<String, dynamic>? user;
  final VoidCallback onClose;
  final VoidCallback onShowKvkk;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset('assets/images/side_logo.png', height: 64),
                  const SizedBox(height: 12),
                  const Divider(height: 1), // <— logo sonrası çizgi
                  const SizedBox(height: 12),
                  if (user == null)
                    const Text(
                      'Bilgilerinizi görmek için giriş yapmanız gerekiyor.',
                      textAlign: TextAlign.center,
                    )
                  else
                    _UserBlock(user: user),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  ListTile(
                    title: const Text(
                      'KVKK Aydınlatma Metni',
                      textAlign: TextAlign.center,
                    ),
                    onTap: onShowKvkk, // <— her zaman var
                  ),
                  if (user != null)
                    ListTile(
                      title: const Text(
                        'Oturumu kapat',
                        textAlign: TextAlign.center,
                      ),
                      onTap: onLogout, // <— profilin altında logout
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            TextButton(
              onPressed: onClose,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Kapat'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserBlock extends StatelessWidget {
  const _UserBlock({required this.user});
  final Map<String, dynamic>? user;

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> u = user!;
    String line(String label, dynamic v) =>
        v == null || (v is String && v.trim().isEmpty) ? '' : '$label: $v';

    final lines = [
      line('Ad Soyad', u['adsoyad']),
      line('Kullanıcı Adı', u['kadi']),
      line('E-posta', u['email']),
      line('Doğum Tarihi', u['dogumtarih']), // dikkat: endpoint’te 'i' yok
      line('Şehir', u['sehir']),
      line('Boy', u['boy']),
      line('Kilo', u['kilo']),
      line('Doktor', u['doktor']),
    ].where((s) => s.isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(s),
          ),
      ],
    );
  }
}

/// ------------------------------
/// KVKK Modal
/// ------------------------------
class _KvkkView extends StatelessWidget {
  const _KvkkView();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 600,
      height: 500,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'KVKK Aydınlatma Metni',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1),
          const Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Text(
                'KİŞİSEL VERİLERİN KORUNMASI KANUNU (KVKK) KAPSAMINDA AYDINLATMA METNİ\n\n'
                    'İşbu aydınlatma metni, 6698 sayılı Kişisel Verilerin Korunması Kanunu (“KVKK”) kapsamında veri sorumlusu sıfatıyla '
                    'Kontinans Derneği tarafından hazırlanmıştır.\n\n'
                    '1. Veri Sorumlusu\n'
                    'Kontinans Derneği\n'
                    'www.kontinansdernegi.org\n'
                    'İletişim: [info@kontinansdernegi.org]\n\n'
                    '2. İşlenen Kişisel Veriler\n'
                    'Formlar aracılığıyla tarafınızdan aşağıdaki kişisel veriler işlenmektedir:\n\n'
                    'Ad, soyad, yaş, cinsiyet, meslek, iletişim bilgileri\n\n'
                    'Sağlık verileri (form içeriklerindeki anket verileri)\n\n'
                    'IP adresi ve işlem kayıtları (log)\n\n'
                    '3. İşleme Amaçları\n'
                    'Kişisel verileriniz;\n\n'
                    'Tıbbi değerlendirme ve istatistiksel analiz yapılması\n\n'
                    'Dernek faaliyetlerinin geliştirilmesi\n\n'
                    'Sağlık alanında bilimsel çalışma, raporlama ve akademik yayın süreçlerine katkı\n'
                    'amaçlarıyla sınırlı olarak işlenmektedir.\n\n'
                    '4. Hukuki Sebep\n'
                    'Kişisel verileriniz, açık rızanıza dayanarak KVKK’nın 5. ve 6. maddelerine uygun şekilde işlenmektedir.\n'
                    'Sağlık verileri özel nitelikli kişisel veridir ve ilgili kişinin açık rızası olmadan işlenemez.\n\n'
                    '5. Veri Saklama Süresi\n'
                    'Form aracılığıyla toplanan kişisel verileriniz, işleme amacının gerektirdiği süre boyunca ve en fazla 5 (beş) yıl süreyle saklanacaktır. '
                    'Süre sonunda anonimleştirilerek veya tamamen silinerek imha edilir.\n\n'
                    '6. Verilerin Aktarımı\n'
                    'Verileriniz, yurt içinde yalnızca gerekli olması hâlinde, tıbbi değerlendirme süreçlerinde görevli yetkililere ve hukuken yetkili kurumlara aktarılabilir. '
                    'Veriler yurt dışına aktarılmaz.\n\n'
                    '7. KVKK Kapsamındaki Haklarınız\n'
                    'KVKK’nın 11. maddesi uyarınca;\n\n'
                    'Kişisel verilerinizin işlenip işlenmediğini öğrenme,\n\n'
                    'İşlenmişse buna ilişkin bilgi talep etme,\n\n'
                    'Hangi amaçla işlendiğini ve bu amaçlara uygun kullanılıp kullanılmadığını öğrenme,\n\n'
                    'Yanlış veya eksik işlenmişse düzeltilmesini talep etme,\n\n'
                    'Verilerinizin silinmesini veya yok edilmesini isteme,\n\n'
                    'Haklarınızı ihlal eden işlemlere karşı ilgili kuruma şikayette bulunma\n'
                    'haklarına sahipsiniz.\n\n'
                    'Başvurularınızı info@kontinansdernegi.org adresinden bize iletebilirsiniz.',
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Kapat'),
            ),
          )
        ],
      ),
    );
  }
}

/// ------------------------------
/// Offline ekranı
/// ------------------------------
class _OfflineView extends StatelessWidget {
  const _OfflineView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 64),
            const SizedBox(height: 12),
            const Text('Bağlantı yok',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              'Lütfen internet bağlantınızı kontrol edip tekrar deneyin.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Tekrar dene')),
          ],
        ),
      ),
    );
  }
}

/// ------------------------------
/// Web hata ekranı (sunucu / SSL / domain hatası vs.)
/// ------------------------------
class _WebErrorView extends StatelessWidget {
  const _WebErrorView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64),
            const SizedBox(height: 12),
            const Text(
              'Formlara şu anda ulaşılamıyor.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Lütfen internet bağlantınızı ve sunucu erişimini kontrol edip tekrar deneyin.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Tekrar dene'),
            ),
          ],
        ),
      ),
    );
  }
}
