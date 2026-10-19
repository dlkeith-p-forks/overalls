import RFB from "../vendor/novnc/core/rfb.js";
import {createAndroidDisplay} from "./android_display_hook.js";

export const AndroidDisplay = createAndroidDisplay(RFB);
