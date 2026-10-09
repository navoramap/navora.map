import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/explore_highlight_service.dart';
import 'explore_highlight_manager_sheet.dart';

class ExplorePage extends StatefulWidget {
  final ValueChanged<String> onSelectListingType;
  final VoidCallback? onSelectLostPet;
  final List<Map<String, String>> savedAddresses;
  final List<Map<String, dynamic>> communityPlaces;
  final List<Map<String, String>> recentSearches;
  final void Function(String label, String query) onSearchCategory;
  final VoidCallback onAddCommunityPlace;
  final ValueChanged<Map<String, dynamic>> onSelectCommunityPlace;
  final VoidCallback onShowCommunityPlaces;
  final String? currentUserUid;
  final bool canManageHighlights;

  const ExplorePage({
    super.key,
    required this.onSelectListingType,
    required this.savedAddresses,
    required this.communityPlaces,
    required this.recentSearches,
    required this.onSearchCategory,
    required this.onAddCommunityPlace,
    required this.onSelectCommunityPlace,
    required this.onShowCommunityPlaces,
    required this.currentUserUid,
    required this.canManageHighlights,
    this.onSelectLostPet,
  });

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  static final _highlightService = ExploreHighlightService();
  static const _placeCategories = [
    _ExploreImageTileData(
      label: 'Kafeler',
      query: 'kafeler',
      imageUrl:
          'https://images.unsplash.com/photo-1445116572660-236099ec97a0?auto=format&fit=crop&w=700&h=420&q=82',
      icon: Icons.local_cafe_rounded,
    ),
    _ExploreImageTileData(
      label: 'Restoranlar',
      query: 'restoranlar',
      imageUrl:
          'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=700&h=420&q=82',
      icon: Icons.restaurant_rounded,
    ),
    _ExploreImageTileData(
      label: 'Doğa',
      query: 'doğa parkları ve sahiller',
      imageUrl: _ExplorePageState._nearbyImage,
      icon: Icons.park_rounded,
    ),
    _ExploreImageTileData(
      label: 'Tarih & kültür',
      query: 'müzeler ve tarihi yerler',
      imageUrl: _ExplorePageState._galleryImage,
      icon: Icons.museum_rounded,
    ),
    _ExploreImageTileData(
      label: 'Alışveriş',
      query: 'alışveriş merkezleri ve çarşılar',
      imageUrl:
          'https://images.unsplash.com/photo-1441986300917-64674bd600d8?auto=format&fit=crop&w=700&h=420&q=82',
      icon: Icons.shopping_bag_rounded,
    ),
    _ExploreImageTileData(
      label: 'Etkinlikler',
      query: 'bugün etkinlikleri konserler festivaller',
      imageUrl: _ExplorePageState._festivalImage,
      icon: Icons.event_rounded,
    ),
  ];
  static const _rentImage =
      'https://images.unsplash.com/photo-1600585154340-be6161a56a0c?auto=format&fit=crop&w=900&q=85';
  static const _saleImage =
      'https://images.unsplash.com/photo-1600607687939-ce8a6c25118c?auto=format&fit=crop&w=900&q=85';
  static const _lostPetImage =
      'https://images.unsplash.com/photo-1623387641168-d9803ddd3f35?auto=format&fit=crop&crop=faces&w=1200&h=380&q=90';
  static const _nearbyImage =
      'https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=1200&h=500&q=85';
    static const _communityPlacesImage =
      'https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=1200&h=500&q=85';
  static const _festivalImage =
      'https://images.unsplash.com/photo-1492684223066-81342ee5ff30?auto=format&fit=crop&w=700&h=420&q=82';
  static const _galleryImage =
      'https://images.unsplash.com/photo-1789913131373-9b3778698580?auto=format&fit=crop&w=700&h=420&q=82';
  static const _facebookUrl = 'https://www.facebook.com/navoramap';
  static const _xUrl = 'https://x.com/navoramap';
  static const _instagramUrl = 'https://www.instagram.com/navoramap';

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF111111),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 12, 18),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Keşfet',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (widget.canManageHighlights)
                    IconButton(
                      tooltip: 'Öne çıkanları yönet',
                      onPressed: () => _openHighlightManager(context),
                      icon: const Icon(Icons.edit_note_rounded),
                      color: const Color(0xFFFF9A3D),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 104),
                children: [
                  if (widget.currentUserUid != null) ...[
                    _buildHighlightCarousel(context),
                    const SizedBox(height: 24),
                  ],
                  const _SectionHeading(title: 'EV & YAŞAM'),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _ListingCategoryCard(
                          title: 'Kiralık Ev',
                          subtitle: 'Kiralık ilanları keşfet',
                          imageUrl: _rentImage,
                          icon: Icons.key_rounded,
                          onTap: () => widget.onSelectListingType('kiralik'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ListingCategoryCard(
                          title: 'Satılık Ev',
                          subtitle: 'Yeni evini bul',
                          imageUrl: _saleImage,
                          icon: Icons.home_rounded,
                          onTap: () => widget.onSelectListingType('satilik'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  const _SectionHeading(title: 'BİZİ TAKİP EDİN'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _SocialFollowButton(
                          label: 'Facebook',
                          icon: FontAwesomeIcons.facebookF,
                          color: const Color(0xFF1877F2),
                          onTap: () =>
                              _openSocialProfile(context, _facebookUrl),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _SocialFollowButton(
                          label: 'X',
                          icon: FontAwesomeIcons.xTwitter,
                          color: Colors.white,
                          onTap: () => _openSocialProfile(context, _xUrl),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _SocialFollowButton(
                          label: 'Instagram',
                          icon: FontAwesomeIcons.instagram,
                          color: const Color(0xFFE1306C),
                          onTap: () =>
                              _openSocialProfile(context, _instagramUrl),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  const _SectionHeading(title: 'MEKÂN ÖNERİLERİ'),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 88,
                    child: _ExploreImageCard(
                      imageUrl: _communityPlacesImage,
                      title: 'Keşfedilmemiş Yerler',
                      subtitle: 'Topluluğun eklediği yerleri haritada keşfet',
                      icon: Icons.place_rounded,
                      onTap: widget.onShowCommunityPlaces,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ExploreImageGrid(
                    items: _placeCategories,
                    onTap: (label, query) => widget.onSearchCategory(
                      'Mekânlar • $label',
                      query,
                    ),
                  ),
                  if (widget.currentUserUid != null) ...[
                    const SizedBox(height: 26),
                    Row(
                      children: [
                        const Expanded(
                          child: _SectionHeading(
                            title: 'TOPLULUK MEKÂNLARI',
                          ),
                        ),
                        IconButton(
                          tooltip: 'Yeni mekân ekle',
                          onPressed: widget.onAddCommunityPlace,
                          icon: const Icon(Icons.add_location_alt_outlined),
                          color: const Color(0xFFFF9A3D),
                        ),
                      ],
                    ),
                    if (widget.communityPlaces.isEmpty)
                      const Text(
                        'İlk keşfettiğin yeri haritaya ekle.',
                        style: TextStyle(
                          color: Color(0xFFB8B8B8),
                          fontSize: 13,
                        ),
                      )
                    else
                      ...widget.communityPlaces.take(8).map(
                        (place) => _ExploreListTile(
                          icon: Icons.place_rounded,
                          title: place['name']?.toString() ?? 'Topluluk mekânı',
                          subtitle: [
                            place['category']?.toString(),
                            place['address']?.toString(),
                          ].where((part) => part != null && part.isNotEmpty).join(' • '),
                          onTap: () => widget.onSelectCommunityPlace(place),
                        ),
                      ),
                  ],
                  if (widget.savedAddresses.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    const _SectionHeading(title: 'KAYDEDİLEN YERLER'),
                    const SizedBox(height: 8),
                    ...widget.savedAddresses
                        .take(4)
                        .map(
                          (address) => _ExploreListTile(
                            icon: Icons.bookmark_outline_rounded,
                            title: address['title'] ?? 'Kayıtlı yer',
                            subtitle: address['address'] ?? '',
                            onTap: () => widget.onSearchCategory(
                              'Kayıtlı yer',
                              address['address'] ?? address['title'] ?? '',
                            ),
                          ),
                        ),
                  ],
                  if (widget.recentSearches.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    const _SectionHeading(title: 'SON BAKTIKLARIN'),
                    const SizedBox(height: 8),
                    ...widget.recentSearches
                        .take(4)
                        .map(
                          (search) => _ExploreListTile(
                            icon: Icons.history_rounded,
                            title: search['name'] ?? search['query'] ?? 'Arama',
                            subtitle: search['query'] ?? '',
                            onTap: () => widget.onSearchCategory(
                              'Son aramalar',
                              search['query'] ?? search['name'] ?? '',
                            ),
                          ),
                        ),
                  ],
                  const SizedBox(height: 26),
                  const _SectionHeading(title: 'TOPLULUK'),
                  const SizedBox(height: 12),
                  _LostPetsCategory(onTap: widget.onSelectLostPet),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightCarousel(BuildContext context) {
    return StreamBuilder<List<ExploreHighlight>>(
      stream: _highlightService.watchActive(),
      builder: (context, snapshot) {
        final highlights = snapshot.data ?? const <ExploreHighlight>[];
        if (snapshot.hasError) {
          return const SizedBox.shrink();
        }
        if (highlights.isEmpty) {
          if (!widget.canManageHighlights) return const SizedBox.shrink();
          return SizedBox(
            height: 142,
            child: _ExploreImageCard(
              imageUrl: _nearbyImage,
              title: 'Öne çıkan kart ekle',
              subtitle: 'Yenilik, rota ve duyurularını burada yayınla',
              icon: Icons.add_rounded,
              onTap: () => _openHighlightManager(context),
            ),
          );
        }
        return SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 20),
            itemCount: highlights.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final highlight = highlights[index];
              return SizedBox(
                width: 280,
                child: _ExploreImageCard(
                  imageUrl: highlight.imageUrl,
                  title: highlight.title,
                  subtitle: highlight.subtitle,
                  icon: _highlightIcon(highlight.iconName),
                  onTap: () => _openHighlight(context, highlight),
                ),
              );
            },
          ),
        );
      },
    );
  }

  IconData _highlightIcon(String name) => switch (name) {
    'pedal_bike' => Icons.pedal_bike_rounded,
    'route' => Icons.route_rounded,
    'place' => Icons.place_rounded,
    'event' => Icons.event_rounded,
    'travel_explore' => Icons.travel_explore_rounded,
    'local_offer' => Icons.local_offer_rounded,
    'campaign' => Icons.campaign_rounded,
    _ => Icons.new_releases_rounded,
  };

  Future<void> _openHighlight(
    BuildContext context,
    ExploreHighlight highlight,
  ) async {
    final actionUrl = highlight.actionUrl.trim();
    if (actionUrl.isNotEmpty) {
      final launched = await launchUrl(
        Uri.parse(actionUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Bağlantı açılamadı.')));
      }
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(highlight.title),
        content: Text(highlight.subtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  Future<void> _openHighlightManager(BuildContext context) async {
    final uid = widget.currentUserUid;
    if (!widget.canManageHighlights || uid == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (context) => ExploreHighlightManagerSheet(
        adminUid: uid,
        service: _highlightService,
      ),
    );
  }

  Future<void> _openSocialProfile(BuildContext context, String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profil açılamadı.')));
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profil açılamadı.')));
    }
  }

}

class _SocialFollowButton extends StatelessWidget {
  final String label;
  final FaIconData icon;
  final Color color;
  final VoidCallback onTap;

  const _SocialFollowButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1D1D1D),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 68,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FaIcon(icon, color: color, size: 21),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFE8E8E8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExploreImageTileData {
  final String label;
  final String query;
  final String imageUrl;
  final IconData icon;

  const _ExploreImageTileData({
    required this.label,
    required this.query,
    required this.imageUrl,
    required this.icon,
  });
}

class _ExploreImageGrid extends StatelessWidget {
  final List<_ExploreImageTileData> items;
  final void Function(String label, String query) onTap;

  const _ExploreImageGrid({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        mainAxisExtent: 88,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return _ExploreImageCard(
          imageUrl: item.imageUrl,
          title: item.label,
          icon: item.icon,
          onTap: () => onTap(item.label, item.query),
        );
      },
    );
  }
}

class _ExploreImageCard extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _ExploreImageCard({
    required this.imageUrl,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF252525),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const ColoredBox(
                color: Color(0xFF29302F),
                child: Center(
                  child: Icon(
                    Icons.explore_rounded,
                    color: Color(0xFFFF9A3D),
                    size: 28,
                  ),
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x12000000), Color(0xD9000000)],
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xD9FF7A00),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: Colors.white, size: 17),
              ),
            ),
            Positioned(
              right: 10,
              top: 12,
              child: Icon(
                Icons.arrow_outward_rounded,
                color: Colors.white.withValues(alpha: 0.9),
                size: 17,
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 11,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFE0E0E0),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExploreListTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ExploreListTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(icon, color: const Color(0xFFFF9A3D), size: 21),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 12),
              ),
        trailing: const Icon(
          Icons.north_west_rounded,
          size: 16,
          color: Colors.white54,
        ),
        onTap: onTap,
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String title;

  const _SectionHeading({required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFFFF7A00),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFFFB36B),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _ListingCategoryCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String imageUrl;
  final IconData icon;
  final VoidCallback onTap;

  const _ListingCategoryCard({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 0.76,
      child: Material(
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const ColoredBox(
                  color: Color(0xFF29302F),
                  child: Center(
                    child: Icon(
                      Icons.home_work_rounded,
                      color: Color(0xFFB9C8BE),
                      size: 42,
                    ),
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x16000000),
                      Color(0x20000000),
                      Color(0xE8000000),
                    ],
                    stops: [0, 0.38, 1],
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF7A00),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: Colors.white, size: 19),
                ),
              ),
              Positioned(
                left: 14,
                right: 12,
                bottom: 15,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFDADADA),
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const Positioned(
                right: 12,
                top: 12,
                child: Icon(
                  Icons.arrow_outward_rounded,
                  color: Color(0xE6FFFFFF),
                  size: 19,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LostPetsCategory extends StatelessWidget {
  static const _borderRadius = BorderRadius.all(Radius.circular(22));

  final VoidCallback? onTap;

  const _LostPetsCategory({this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B201D),
      borderRadius: _borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: _borderRadius,
        child: SizedBox(
          height: 112,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                _ExplorePageState._lostPetImage,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const ColoredBox(
                  color: Color(0xFF29302F),
                  child: Center(
                    child: Icon(
                      Icons.pets_rounded,
                      color: Color(0xFFA9C5B0),
                      size: 25,
                    ),
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xCC101410),
                      Color(0x99101410),
                      Color(0x55101410),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.pets_rounded,
                      color: Colors.white,
                      size: 25,
                    ),
                    const SizedBox(width: 13),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Can dostlar',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Kayıp, bulunan ve yuva arayan hayvanları keşfet',
                            style: TextStyle(
                              color: Color(0xFFF0F0F0),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.white,
                      size: 19,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
