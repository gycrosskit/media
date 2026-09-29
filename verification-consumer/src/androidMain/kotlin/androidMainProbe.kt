import io.github.gycrosskit.media.*
import androidx.activity.ComponentActivity
fun androidPicker(activity: ComponentActivity) = AndroidImagePickerPlatform(activity, { MediaPermissionState.GRANTED })
fun androidSaver(activity: ComponentActivity) = AndroidImageSavePlatform(activity, { MediaPermissionState.GRANTED })
