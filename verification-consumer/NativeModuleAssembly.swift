import MediaConsumer
import GycMediaKuikly

// 编译生成的真实 consumer framework API；宿主只装配方法引用，不实现 transport。
public func configureMediaModule(picker: ImagePickerPlatform, saver: ImageSavePlatform) {
    GycMedia.configure {
        let handler = IosMediaModuleHandler(picker: picker, saver: saver)
        return (call: handler.call, dispose: handler.dispose)
    }
}
