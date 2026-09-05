import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 沉浸式顶栏：隐藏系统标题栏文字与底色，Flutter 内容延伸到标题栏区域，
    // 由 App 自绘 AppBar 承担顶栏角色（交通灯悬浮在左上角）
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    // 空白区域可拖动窗口（Apple 惯例）
    self.isMovableByWindowBackground = true

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
