<p align="center"><img src="docs/images/icon.png" width="120" alt="Icono de Changmun"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>Un navegador ligero para Mac con barra lateral y una IA que sabe usarlo.</b><br>
  El motor WebKit de Safari, pestañas verticales, favoritos y carpetas de marcadores a la izquierda, y un panel de Claude que lee páginas, hace clic y escribe por ti.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 o posterior">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="Licencia MIT"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="Swift nativo">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a> · <b>Español</b> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/images/window.png" width="760" alt="Ventana de Changmun con pestañas verticales en la barra lateral y una tarjeta de página">
</p>

*Changmun* (창문) significa *ventana* en coreano. Es gratuito, de código abierto y no tiene cuentas ni rastreo. La app está disponible en inglés, coreano, japonés, chino simplificado, español, alemán y francés.

## Instalar

```sh
brew install --cask namekun/tap/changmun
```

Necesitas [Homebrew](https://brew.sh), macOS 14 Sonoma o posterior y un Mac con Apple silicon. Homebrew quita la marca de cuarentena, así que la app se abre directamente. Para actualizar, ejecuta `brew update && brew upgrade --cask changmun`.

En el primer arranque, Changmun te ofrece traer los marcadores, el historial, las contraseñas y los inicios de sesión del navegador que usas ahora.

### Compilar desde el código fuente

Necesitas macOS 14 o posterior y Xcode o las Command Line Tools.

```sh
git clone https://github.com/namekun/Changmun.git
cd Changmun
scripts/bundle.sh release   # makes build/Changmun.app
open build/Changmun.app
```

Si solo tienes instaladas las Command Line Tools, los scripts compilan con el SDK de macOS 26 (el plugin de macros de SwiftUI del SDK de macOS 27 solo viene con Xcode). Los productos de la compilación van a `~/Library/Caches/Changmun/build`, fuera del alcance de la sincronización del Escritorio con iCloud.

## Qué hace

- **Barra lateral.** Favoritos como mosaicos, carpetas de marcadores y pestañas verticales. Arrastra las pestañas para reordenarlas, o suéltalas sobre los favoritos para fijarlas. Los favoritos y los marcadores tienen cada uno su propia pestaña, como en Dia y Arc: al hacer clic en uno, vas a su pestaña en lugar de reemplazar la que estás leyendo (⌘-clic abre una pestaña nueva). Arrastra un enlace de una página a la barra lateral para abrirlo como pestaña, guardarlo como favorito o archivarlo en una carpeta. El menú de una pestaña también la recarga, la duplica, la mueve a una ventana nueva, la comparte o la abre en otro navegador. Cerrar las pestañas de un grupo o eliminar un marcador se puede deshacer durante unos segundos.
- **La barra de direcciones donde prefieras.** Arriba de la barra lateral, bajo atrás y adelante, como en Arc, o sobre la página, como en Dia: Ajustes › Aspecto › Posición de la barra de direcciones. Solo muestra el sitio; el escudo y la estrella aparecen al pasar el puntero. En una página favorita la estrella se queda: haz clic en ella para quitarla de favoritos.
- **Carpetas de marcadores.** Las carpetas importadas conservan su anidación, como en el navegador del que vienen. Fija las que uses en la barra lateral (clic derecho o … › Fijar en la barra lateral, o arrastra la carpeta debajo de los favoritos) y ábrelas ahí mismo. Arrastra un marcador a otra carpeta o a los favoritos, o usa Mover a en su menú. El resto de tus marcadores está tras el botón de marcadores, abajo en la barra lateral, con un campo de búsqueda; el … de al lado abre el Historial, las Pestañas archivadas, el Modo concentración y los Ajustes.
- **Grupos de pestañas.** Clic derecho en una pestaña › Añadir a un grupo nuevo, ponle nombre y pliégalo. Las pestañas que se abren desde la pestaña de un grupo se unen a él; una pestaña reabierta (⌘⇧T) vuelve a su grupo.
- **Ordenar pestañas.** La varita junto a "Nueva pestaña" (Ventana › Ordenar pestañas) agrupa las pestañas sueltas. Con Apple Intelligence activada (macOS 26), el modelo de tu Mac las agrupa por tema y pone nombre a los grupos; nada sobre tus pestañas sale del Mac. Sin ella, se agrupan las pestañas abiertas unas desde otras y las de un mismo sitio. "Deshacer" lo devuelve todo a su sitio durante unos segundos. Las pestañas nuevas que abres desde la barra de direcciones se unen por sí solas a un grupo que encaje (desactívalo en Ajustes › Pestañas).
- **Archivar pestañas antiguas** (desactivado por defecto). Las pestañas que no has mirado durante un tiempo determinado (de 12 horas a 30 días, contado solo mientras Changmun está abierto) se cierran en Historial › Pestañas archivadas, listas para volver a abrirse en su grupo. Las pestañas visibles, con reproducción, en imagen en imagen, con cámara o micrófono, las favoritas y las privadas nunca se archivan.
- **Vista dividida** (⌥⌘\\) muestra dos pestañas una junto a otra. **Modo concentración** (⌘⇧F) oculta todo menos la página. **Vista previa de enlaces**: ⇧-clic en un enlace para abrirlo en una tarjeta flotante, ⌘↩ para conservarlo como pestaña.
- **Las ventanas privadas** guardan sus cookies y datos de sitios web en memoria y los olvidan al cerrarse; nada va al historial, a la sesión ni a la IA.
- **Barra de comandos** (⌘T): búsqueda, direcciones, cambio a pestañas abiertas, marcadores e historial, y preguntas a la IA.
- **Traduce páginas** en el sitio con la traducción en el dispositivo de macOS (⌥⌘T, macOS 26 o posterior). Los enlaces y el diseño se mantienen; el texto nunca sale del Mac.
- **Ajustes del sitio.** Haz clic en el candado y el nombre del sitio en la barra de direcciones para ver un panel pequeño con lo que Changmun guarda de ese sitio: bloqueo de anuncios, zoom, ventanas emergentes, cámara y micrófono, y si sus pestañas pueden suspenderse. Haz clic en cualquier otra parte de la barra para editar la dirección, como siempre.
- **Modo lectura** (⇧⌘R, o ⌥⌘R con los atajos al estilo de Chrome) muestra un artículo como texto limpio y legible sobre la página. Cuando la página parece un artículo, aparece un botón en la barra de direcciones. Esc, la × o la misma tecla devuelven la página tal como estaba. Lo hace un pequeño script de la página; no se descarga ni se envía nada.
- **Imagen en imagen** (⌃⌘P) se activa sola cuando sales de una pestaña con un vídeo en reproducción. ⌃⌘← / ⌃⌘→ saltan 5 segundos incluso mientras estás en otra app, y "Volver a la pestaña" trae la pestaña al frente.
- **Las contraseñas** se guardan en el llavero después de iniciar sesión (solo https) y se rellenan desde la llave de la barra de direcciones. Para copiar una se pide Touch ID o la contraseña de tu Mac.
- **Las ventanas emergentes** que se abren sin un clic se bloquean, con "Abrir" y "Permitir siempre en este sitio" justo encima de la página.
- **Las descargas** muestran su progreso en la parte inferior de la barra lateral y reciben la marca de cuarentena de Safari, así que Gatekeeper las comprueba la primera vez que se abren. Las apps, los scripts y los instaladores se muestran en el Finder en lugar de ejecutarse. Una descarga interrumpida continúa desde donde se quedó con Reintentar en su fila.
- **Pestañas suspendidas.** Las pestañas en segundo plano que no has visto en 20 minutos, y todas las pestañas en segundo plano cuando hay poca memoria, devuelven su proceso web y vuelven con su historial cuando regresas a ellas.
- El zoom de página se recuerda por sitio, y las pestañas abiertas se guardan cada 15 segundos, así que un cierre inesperado cuesta casi nada.
- **Aviso de actualización.** Changmun se actualiza con Homebrew. Una vez al día pregunta a GitHub por la última versión y, si hay una más reciente, una nota discreta al final de la barra lateral copia `brew upgrade --cask changmun` por ti. Desactívalo en Ajustes › Avanzado › Buscar actualizaciones.

## Atajos

Elige estilo Safari o estilo Chrome en Ajustes (⌘,). Solo cambian las teclas en las que los dos navegadores discrepan.

| Teclas | Acción |
| --- | --- |
| ⌘T / ⌘L | Barra de comandos / editar la dirección actual |
| ⌘E / ⌘⇧E | Panel de IA / nuevo chat de IA |
| ⌘D | Añadir o quitar un favorito |
| ⌘N / ⌘⇧N / ⌘⇧W | Nueva ventana / nueva ventana privada / cerrar ventana |
| ⌘W, ⌘1–9, ⌘⇧[ ⌘⇧] | Cerrar pestaña, ir a una pestaña según el orden de la barra lateral |
| ⌃Tab / ⌃⇧Tab | Cambiar de pestaña en el orden en que las viste por última vez (mantén ⌃, pulsa Tab, suelta; esc cancela) |
| ⌥⌘\\ | Activar o desactivar la vista dividida |
| ⇧-clic | Vista previa de enlaces: esc la cierra, ⌘↩ la abre como pestaña |
| ⌘⇧T | Reabrir la pestaña cerrada (o la ventana cerrada si no queda ninguna pestaña) |
| ⌃⌘M | Silenciar o dejar de silenciar la pestaña |
| ⌃⌘P | Activar o desactivar imagen en imagen |
| ⌃⌘← / ⌃⌘→ | Retroceder o avanzar el vídeo 5 segundos |
| ⌥⌘T | Traducir la página / mostrar el original |
| ⌘F, ⌘G, ⌘⇧G | Buscar en la página, siguiente, anterior |
| ⌘Y | Historial |
| ⌘O, ⌘P, ⌘⇧C | Abrir archivo, imprimir, copiar la dirección |
| F12 o ⌥⌘I | Inspector web |
| ⌘⇧F | Modo concentración |

| Acción | Estilo Safari | Estilo Chrome |
| --- | --- | --- |
| Barra lateral | ⌘⇧L | ⌘S |
| Recarga forzada | ⌥⌘R | ⌘⇧R |
| Modo lectura | ⇧⌘R | ⌥⌘R |
| Consola | ⌥⌘C | ⌥⌘J |
| Descargas | ⌥⌘L | ⌘⇧J |
| Pestaña anterior / Pestaña siguiente | | ⌥⌘← ⌥⌘→ |

## IA

El panel de la derecha (⌘E) usa la CLI `claude` que ya tienes, así que funciona con tu suscripción a Claude Code. El modelo por defecto es Sonnet; cámbialo con `defaults write io.github.namekun.Changmun aiModel opus`.

La IA maneja el navegador con estas herramientas: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `click`, `type_text`, `scroll`, `screenshot`. No puede leer ni rellenar campos de contraseña.

Para que unas instrucciones ocultas en una página no puedan hacer que lleve a otro sitio lo que ha leído, Changmun te pregunta primero (y responde que no tras 90 segundos sin respuesta):

- antes de que use una pestaña que no estás mirando, una vez por pestaña y sitio;
- antes de que abra una dirección, salvo que sea una búsqueda, una dirección ya abierta, visitada o guardada en marcadores, o la página principal de un sitio conocido;
- antes de cada escritura una vez que el chat ha leído otro sitio, mostrándote lo que va a escribir. Un chat nuevo (⌘⇧E) empieza de cero.

Otros agentes, como Claude Code, pueden usar las mismas herramientas mediante MCP, con las mismas preguntas:

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

`--mcp` inicia Changmun si no está en marcha. El servidor de control solo escucha en 127.0.0.1 y requiere un token que cambia en cada arranque.

O desde una shell, para cualquier agente que pueda ejecutar órdenes (Homebrew pone `changmun` en el PATH):

```sh
changmun tabs
changmun open example.com
changmun read
changmun click 12
changmun type 3 "hello" --submit
```

`changmun help` muestra el resto. Cada orden es una de las mismas herramientas, con las mismas preguntas, y abre Changmun si hace falta.

## Bloqueo de anuncios

Changmun convierte EasyList (anuncios) y EasyPrivacy (rastreadores) en reglas de bloqueo de contenido de WebKit y las actualiza cada 4 días. En Ajustes › Privacidad puedes desactivar listas o añadir otras por su dirección (una lista de anuncios coreana está a un clic). Si un sitio se rompe, el escudo de la barra de direcciones desactiva el bloqueo para ese sitio. Las reglas que WebKit no puede expresar (expresiones regulares, `$redirect`, scriptlets, `:has-text` y otros selectores extendidos) se omiten en lugar de adivinarse.

## Extensiones

Se gestionan en Ajustes › Extensiones (las extensiones web requieren macOS 15.4 o posterior).

- **Las extensiones de Safari de la App Store** aparecen una vez instaladas y piden sus permisos cuando las activas.
- **Extensiones de Chrome Web Store**: abre la página de una extensión en la tienda y aparece "Añadir a Changmun" encima (o pega su dirección o ID en Ajustes). Changmun la descomprime en `~/Library/Application Support/Changmun/Extensions` y la carga como extensión de WebKit; si la añades de nuevo, se actualiza.
- **Bloqueadores de contenido de Safari** (Unicorn, AdGuard y otros): macOS solo permite que Safari pida las reglas a un bloqueador, así que Changmun lee el archivo de reglas que el bloqueador guardó. macOS pregunta una vez si le permites leer los datos de otra app.
- También se carga una carpeta de extensión sin empaquetar (con `manifest.json`). Algunas funciones, como la comunicación con una app nativa, pueden no funcionar.

## Importar desde otros navegadores

En el primer arranque, o desde el menú, Changmun importa marcadores e historial de Safari y de los navegadores Chromium: Chrome, Arc (con su barra lateral), Dia, Aside, Whale, Brave, Edge, Vivaldi. De los navegadores Chromium también trae las contraseñas y las cookies, para que sigas con la sesión iniciada.

- Las contraseñas y las cookies se descifran con el elemento del llavero de cada navegador (`<name> Safe Storage`), así que macOS te pide que lo permitas. Las contraseñas importadas van a tu llavero de inicio de sesión con la etiqueta `Changmun`.
- Para leer Safari hace falta Acceso total al disco. macOS no entrega las contraseñas de Safari a otras apps.

## Privacidad

- Tu navegación se queda en tu Mac. Changmun no tiene cuentas, servidores ni analíticas.
- La búsqueda de actualizaciones consulta una vez al día la API pública de versiones de GitHub para saber el número de la última versión y no envía nada más (se desactiva en Ajustes › Avanzado).
- Las sugerencias de búsqueda envían a tu buscador lo que escribes en la barra de comandos (desactívalas en Ajustes; nunca se envían desde ventanas privadas).
- El panel de IA envía tus mensajes, y el contenido de las páginas que lee la IA, a Anthropic a través de la CLI `claude`. Ordenar pestañas y la traducción de páginas se ejecutan en tu Mac.

## Para desarrolladores

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

El texto de la interfaz está en inglés en el código y traducido en `Resources/<language>.lproj/Localizable.strings`; añade cada cadena nueva a las seis tablas.

`scripts/headless.sh` ejecuta un Changmun sin interfaz para pruebas y agentes: fuera de pantalla, sin tomar nunca el foco ni reproducir sonido, con su propio perfil en `~/Library/Application Support/Changmun Headless`. No toca el llavero, y responde por sí solo a las confirmaciones de la IA, los permisos de sitios y los diálogos de JavaScript (los permisos se deniegan).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## Licencia

[MIT](LICENSE)
