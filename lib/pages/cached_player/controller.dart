import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:get/get.dart';

class CachedPlayerListController extends GetxController {
  final _downloadService = Get.find<DownloadService>();

  final list = <BiliDownloadEntryInfo>[].obs;

  @override
  void onInit() {
    super.onInit();
    load();
    _downloadService.flagNotifier.add(load);
  }

  @override
  void onClose() {
    _downloadService.flagNotifier.remove(load);
    super.onClose();
  }

  Future<void> load() async {
    await _downloadService.waitForInitialization;
    if (isClosed) return;
    list
      ..clear()
      ..addAll(_downloadService.downloadList)
      ..sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp))
      ..refresh();
  }
}
