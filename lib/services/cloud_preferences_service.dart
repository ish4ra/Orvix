import 'package:shared_preferences/shared_preferences.dart';

enum CloudProvider { pikpak, torbox }

extension CloudProviderLabel on CloudProvider {
  String get label => this == CloudProvider.pikpak ? 'PikPak' : 'TorBox';
}

class CloudPreferencesService {
  static const _key = 'orvix_preferred_cloud_v1';

  Future<CloudProvider> getPreferred() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return CloudProvider.values.firstWhere(
      (provider) => provider.name == value,
      orElse: () => CloudProvider.pikpak,
    );
  }

  Future<void> setPreferred(CloudProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, provider.name);
  }
}
