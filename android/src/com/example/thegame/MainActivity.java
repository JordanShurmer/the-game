package com.example.thegame;

// The whole of the Android app: a WebView, filled from the assets.
//
// The page is served over an origin of its own rather than off a
// file:// path, because a browser gives a file:// page none of what
// WebAssembly needs -- no fetch, no module streaming, and no shared
// origin between the page and the .wasm beside it. Every request the
// WebView makes is answered here, out of the APK, with nothing over the
// network. See docs/web.md, "The APK".

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.IOException;
import java.io.InputStream;
import java.util.Collections;

public class MainActivity extends Activity {

	// The origin the page is served on. It is not a name that resolves:
	// nothing here goes to a network.
	private static final String ORIGIN = "https://the.game/";

	private WebView web;

	@Override
	protected void onCreate(Bundle state) {
		super.onCreate(state);

		getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

		web = new WebView(this);
		WebSettings settings = web.getSettings();
		settings.setJavaScriptEnabled(true);
		settings.setDomStorageEnabled(true);
		settings.setMediaPlaybackRequiresUserGesture(false);
		settings.setCacheMode(WebSettings.LOAD_NO_CACHE);

		web.setWebViewClient(new Assets(this));

		setContentView(web);
		web.loadUrl(ORIGIN + "index.html");
	}

	@Override
	public void onWindowFocusChanged(boolean focused) {
		super.onWindowFocusChanged(focused);
		if (!focused) {
			return;
		}
		// The game draws to the edges and reads a touch itself, so the
		// bars go away and come back on a swipe.
		web.setSystemUiVisibility(
			View.SYSTEM_UI_FLAG_LAYOUT_STABLE
				| View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
				| View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
				| View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
				| View.SYSTEM_UI_FLAG_FULLSCREEN
				| View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
	}

	// Named rather than anonymous, because d8 will not dex an anonymous
	// class out of a recent javac.
	private static final class Assets extends WebViewClient {
		private final MainActivity host;

		Assets(MainActivity host) {
			this.host = host;
		}

		@Override
		public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
			return host.serve(request.getUrl().toString());
		}
	}

	private WebResourceResponse serve(String url) {
		if (!url.startsWith(ORIGIN)) {
			return null;
		}

		String name = url.substring(ORIGIN.length());
		int query = name.indexOf('?');
		if (query >= 0) {
			name = name.substring(0, query);
		}
		if (name.isEmpty()) {
			name = "index.html";
		}
		// Nothing may reach out of the assets directory.
		if (name.contains("..")) {
			return null;
		}

		try {
			InputStream stream = getAssets().open(name);
			WebResourceResponse response = new WebResourceResponse(mimeOf(name), null, stream);
			response.setResponseHeaders(Collections.singletonMap("Cache-Control", "no-store"));
			return response;
		} catch (IOException absent) {
			return null;
		}
	}

	// A WebView refuses a module that is not named application/wasm,
	// and it will not run one it was handed as text.
	private static String mimeOf(String name) {
		if (name.endsWith(".html")) return "text/html";
		if (name.endsWith(".js")) return "text/javascript";
		if (name.endsWith(".wasm")) return "application/wasm";
		if (name.endsWith(".png")) return "image/png";
		if (name.endsWith(".webmanifest")) return "application/manifest+json";
		return "application/octet-stream";
	}
}
