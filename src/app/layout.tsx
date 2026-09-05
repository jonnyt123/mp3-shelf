import type { Metadata, Viewport } from "next";
import { ServiceWorker } from "@/components/service-worker";
import "./styles.css";
import "./player-features.css";
export const metadata: Metadata = { title:"MP3 Shelf", description:"Import your MP3s once, then find and play them quickly.", applicationName:"MP3 Shelf", appleWebApp:{capable:true,statusBarStyle:"black-translucent",title:"MP3 Shelf"} };
export const viewport: Viewport = { themeColor:"#08090d", width:"device-width", initialScale:1, viewportFit:"cover" };
export default function RootLayout({children}:Readonly<{children:React.ReactNode}>){return <html lang="en"><body><ServiceWorker />{children}</body></html>}
