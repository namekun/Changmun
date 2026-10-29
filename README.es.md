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

*Changmun* (창문) significa *ventana* en coreano; como nombre de navegador, más claro, agua. Es gratuito, de código abierto y no tiene cuentas ni rastreo. La app está disponible en inglés, coreano, japonés, chino simplificado, español, alemán y francés.

## Por qué Changmun

- **Ligero.** Cada navegador Chromium trae su propia copia de Chromium. Changmun usa en cambio el motor WebKit que ya viene con macOS, el mismo que usa Safari, así que la descarga pesa unos 3 MB (el DMG de la 0.4.1 son 2,6 MB). Cuida la batería y las correcciones de seguridad del motor llegan con las actualizaciones de macOS y de Safari.
- **Una barra lateral como la de Arc y Dia.** Pestañas verticales, con espacio de sobra para los títulos, favoritos como mosaicos, carpetas de marcadores, grupos de pestañas y espacios. ¿Prefieres una franja de pestañas arriba? Es un ajuste.
- **Una IA que usa el navegador.** El panel de Claude lee páginas y hace clic y escribe por ti con la CLI `claude` que ya tienes. Le presta las manos, pero no le da carta blanca: antes de hacer algo arriesgado, pregunta.
- **Privado por defecto.** Sin cuenta, servidor ni analíticas, así que no hay nada en lo que registrarse. El bloqueo de anuncios y rastreadores viene incluido.
- **Mudanza con muebles incluidos.** Importa marcadores e historial de Safari y de los navegadores Chromium, y de estos últimos también contraseñas e inicios de sesión. Las contraseñas de Safari se quedan donde están: macOS no se las entrega a otras apps.

## Instalar

```sh
brew install --cask namekun/tap/changmun
```

Necesitas [Homebrew](https://brew.sh), macOS 14 Sonoma o posterior y un Mac con Apple silicon. La app está firmada con un Developer ID y notarizada por Apple, así que se abre directamente. Las actualizaciones llegan dentro de la app (Changmun › Buscar actualizaciones…, automáticas por defecto); Homebrew solo hace falta para instalar.

En el primer arranque, Changmun te ofrece traer los marcadores y el historial del navegador que usas ahora y, si es un navegador Chromium, también las contraseñas y los inicios de sesión.

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

### Barra lateral y pestañas

- **Barra lateral.** Reúne tus favoritos, marcadores y pestañas abiertas en una columna a la izquierda: favoritos como mosaicos, carpetas de marcadores y pestañas verticales. Arrastra las pestañas para reordenarlas, o suéltalas sobre los favoritos para fijarlas. Los favoritos y los marcadores tienen cada uno su propia pestaña, como en Dia y Arc: al hacer clic en uno, vas a su pestaña en lugar de reemplazar la que estás leyendo (⌘-clic abre una pestaña nueva). Arrastra un enlace de una página a la barra lateral para abrirlo como pestaña, guardarlo como favorito o archivarlo en una carpeta. El menú de una pestaña también la recarga, la duplica, la mueve a una ventana nueva, la comparte o la abre en otro navegador. Para ponerle a una pestaña un nombre tuyo, haz doble clic en su título o elige Renombrar pestaña… en su menú; el nombre se mantiene al cambiar de página y al reiniciar, y la IA sigue viendo el título real de la página. Los marcadores y sus carpetas se renombran igual (doble clic, o Renombrar… en su menú) y los favoritos desde su menú; el nombre que les pongas se mantiene aunque vuelvas a importar desde ese navegador. Cerrar las pestañas de un grupo o eliminar un marcador se puede deshacer durante unos segundos, que es justo cuando suele llegar el arrepentimiento.
- **La barra de direcciones donde prefieras.** Ponla donde la busca tu mano: arriba de la barra lateral, bajo atrás y adelante, como en Arc, o sobre la página, como en Dia (Ajustes › Aspecto › Posición de la barra de direcciones). Solo muestra el sitio; el escudo y la estrella aparecen al pasar el puntero. En una página favorita la estrella se queda: haz clic en ella para quitarla de favoritos.
- **Pestañas arriba.** ¿Prefieres una franja a una columna? Elige Arriba en Ajustes › Aspecto › Disposición de las pestañas. Una franja horizontal de pestañas queda sobre la barra de direcciones: primero los favoritos, como mosaicos solo con icono, y después las pestañas del espacio, con favicon, título, × para cerrar e indicador de audio. Un grupo de pestañas es una etiqueta de color que lo pliega (la pestaña que estás viendo sigue visible). El botón + sigue a la vista aunque las pestañas desborden, y la franja se desplaza hacia los lados. El clic central cierra una pestaña, arrastrar reordena, el doble clic cambia el nombre, y los menús contextuales son los de la barra lateral. La barra lateral (marcadores, espacios, descargas, menú) se abre sobre la página desde el botón a la izquierda de la barra de direcciones. Barra lateral sigue siendo la opción por defecto.
- **Carpetas de marcadores.** Tus marcadores conservan el orden que les diste y siguen a mano. Las carpetas importadas conservan su anidación, como en el navegador del que vienen. Fija las que uses en la barra lateral (clic derecho o … › Fijar en la barra lateral, o arrastra la carpeta debajo de los favoritos) y ábrelas ahí mismo. Arrastra un marcador a otra carpeta o a los favoritos, o usa Mover a en su menú. El resto de tus marcadores está tras el botón de marcadores, abajo en la barra lateral, con un campo de búsqueda; el … de al lado abre el Historial, las Pestañas archivadas, el Modo concentración y los Ajustes.
- **Lista de lectura.** Guarda una página para leerla más tarde, como en Safari: Historial › Añadir a la lista de lectura (⇧⌘D), el menú de una pestaña o clic derecho en un enlace › Añadir enlace a la lista de lectura. La lista está arriba del todo en el panel del botón de marcadores, abajo en la barra lateral: las páginas sin leer llevan el título en negrita y un punto, cada una muestra su sitio y cuándo la guardaste, y al abrirla se marca como leída. Con clic derecho puedes marcarla como leída o no leída, copiar el enlace o quitarla, y borrar de una vez las ya leídas. Guardar, quitar y borrar se pueden deshacer durante unos segundos. En una ventana privada no se guarda nada, y la IA nunca ve la lista. Al importar de Safari llega también su lista de lectura, con lo que ya habías leído.
- **Grupos de pestañas.** Mantiene juntas las pestañas relacionadas y las quita de en medio. Clic derecho en una pestaña › Añadir a un grupo nuevo, ponle nombre y pliégalo; haz doble clic en la cabecera del grupo (o en su chip de la barra de pestañas) para renombrarlo. Las pestañas que se abren desde la pestaña de un grupo se unen a él; una pestaña reabierta (⌘⇧T) vuelve a su grupo. Arrastra un grupo por su cabecera para moverlo, o hacia arriba, sobre los favoritos o las carpetas fijadas, para guardarlo entero en una sola carpeta de marcadores.
- **Ordenar pestañas.** Convierte un montón de pestañas sueltas en grupos con un solo clic. Un toque de la varita junto a "Nueva pestaña" (Ventana › Ordenar pestañas) y las pestañas sueltas quedan agrupadas. Con Apple Intelligence activada (macOS 26), el modelo de tu Mac las agrupa por tema y pone nombre a los grupos; nada sobre tus pestañas sale del Mac. Sin ella, se agrupan las pestañas abiertas unas desde otras y las de un mismo sitio. "Deshacer" lo devuelve todo a su sitio durante unos segundos. Las pestañas nuevas que abres desde la barra de direcciones se unen por sí solas a un grupo que encaje (desactívalo en Ajustes › Pestañas).
- **Archivar pestañas antiguas** (desactivado por defecto). Aparta las pestañas que ya no miras, pero sin tirarlas. Las pestañas que no has mirado durante un tiempo determinado (de 12 horas a 30 días, contado solo mientras Changmun está abierto) se cierran en Historial › Pestañas archivadas, listas para volver a abrirse en su grupo. Las pestañas visibles, con reproducción, en imagen en imagen, con cámara o micrófono, las favoritas y las privadas nunca se archivan.
- **Pestañas suspendidas.** Deja que las pestañas en segundo plano echen una siesta y te devuelvan la memoria. Las pestañas en segundo plano que no has visto en 20 minutos, y todas las pestañas en segundo plano cuando hay poca memoria, devuelven su proceso web y vuelven con su historial cuando regresas a ellas.
- **Barra de comandos** (⌘T). Un solo cuadro para todo: buscar, escribir direcciones, cambiar a pestañas abiertas, marcadores e historial, y preguntar a la IA.
- **Página de inicio.** Una pestaña nueva puede abrirse en una página hecha a tu medida: un cuadro de búsqueda que funciona como la barra de comandos, tus favoritos, las pestañas que acabas de cerrar, las páginas sin leer de tu lista de lectura y los sitios que más visitas. Elige un estilo (Panel, Tranquilo o IA primero), activa y desactiva secciones, arrástralas a tu orden y escoge como fondo un color, el brillo del espacio o una imagen tuya; el texto se lee bien sobre cualquiera. Las secciones sin nada que mostrar se ocultan solas y una ventana privada no muestra nada del historial. Todo se queda en tu Mac (Personalizar, abajo a la derecha, o Visualización › Personalizar la página de inicio…).
- **VoiceOver y teclado.** La barra lateral, la barra de pestañas, la barra de direcciones, la barra de comandos, la búsqueda en la página, el panel de IA y los Ajustes funcionan con VoiceOver y con el acceso total con el teclado: cada botón, campo, pestaña y fila tiene un nombre (y su estado, si lo tiene), y las filas y los botones se pueden pulsar desde el teclado. Los mensajes de estado se anuncian al aparecer.

### Espacios y perfiles

- **Espacios.** Separa pestañas, grupos de pestañas y favoritos según el tipo de navegación, para que el trabajo no se cuele en tu fin de semana. La fila de la parte inferior de la barra lateral cambia de espacio: haz clic en un punto, pulsa ⌃1–⌃9 o desliza dos dedos hacia un lado sobre la barra lateral (Ventana › Espacio siguiente, Espacio anterior, Nuevo espacio…). Cada espacio tiene sus propias pestañas, grupos de pestañas, favoritos y carpetas fijadas, y tiñe la barra lateral con su color. La biblioteca de marcadores, el historial y las contraseñas guardadas se comparten. Activa «Separar inicios de sesión y cookies (perfil)» al crear un espacio para que tenga también sus propias cookies y datos de sitios, y así un mismo sitio pueda tener dos cuentas abiertas a la vez; después no se puede cambiar, y al eliminar un perfil se borran sus cookies y datos de sitios. Tu primer espacio se crea con lo que ya tenías. Las ventanas privadas no tienen espacios. La IA ve las pestañas de los espacios normales (con el nombre del espacio), pero las de un espacio con perfil solo mientras estás en él.

### Leer y ver

- **Modo lectura.** Lee un artículo como texto limpio y legible. ⇧⌘R (o ⌥⌘R con los atajos al estilo de Chrome) lo muestra sobre la página. Cuando la página parece un artículo, aparece un botón en la barra de direcciones. Esc, la × o la misma tecla devuelven la página tal como estaba. Lo hace un pequeño script de la página: las imágenes del artículo se cargan desde los mismos sitios desde los que las carga la página, y no se descarga ni se envía nada más.
- **Traducción de páginas.** Lee una página en otro idioma sin salir de ella. Se traduce en el sitio con la traducción en el dispositivo de macOS (⌥⌘T, macOS 26 o posterior). Los enlaces y el diseño se mantienen; el texto nunca sale del Mac.
- **Vista dividida** (⌥⌘\\). Para cuando una página no basta: dos pestañas una junto a otra.
- **Modo concentración** (⌘⇧F). Oculta todo menos la página. Concentrarte ya es cosa tuya.
- **Vista previa de enlaces.** Echa un vistazo a un enlace sin salir de la página en la que estás. ⇧-clic en un enlace para abrirlo en una tarjeta flotante, ⌘↩ para conservarlo como pestaña.
- **Imagen en imagen** (⌃⌘P). Mantiene un vídeo a la vista cuando sales de su pestaña. Se activa sola cuando sales de una pestaña con un vídeo en reproducción. ⌃⌘← / ⌃⌘→ saltan 5 segundos incluso mientras estás en otra app, y "Volver a la pestaña" trae la pestaña al frente.

### Privacidad y seguridad

- **Ventanas privadas.** Navega sin dejar rastro. Las ventanas privadas guardan sus cookies y datos de sitios web en memoria y los olvidan al cerrarse; nada va al historial, a la sesión ni a la IA.
- **Ajustes del sitio.** Muestra y cambia en un solo lugar lo que Changmun recuerda de un sitio. Haz clic en el candado, a la izquierda de la barra de direcciones, para ver un panel pequeño con lo que Changmun guarda de ese sitio: bloqueo de anuncios, zoom, ventanas emergentes, cámara y micrófono, y si sus pestañas pueden suspenderse. Haz clic en cualquier otra parte de la barra, incluido el nombre del sitio, para editar la dirección, como siempre.
- **Contraseñas.** Recordarlas es cosa del llavero. Las contraseñas se guardan en el llavero después de iniciar sesión (solo https) y se rellenan desde la llave de la barra de direcciones. Para copiar o rellenar una se pide Touch ID o la contraseña de tu Mac (al rellenar se puede desactivar en Ajustes › Privacidad).
- **Certificados de cliente.** Cuando un sitio pide un certificado para identificarte (una intranet de empresa, un banco), Changmun muestra, en la hoja del propio sistema y como hace Safari, los que hay en tu llavero o en una tarjeta inteligente y que el sitio acepta. Lo que eliges se guarda como preferencia de identidad para ese sitio (se elimina en Acceso a Llaveros) y la próxima visita no pregunta; las ventanas privadas y las páginas que usa la IA no guardan nada. Si cancelas, el sitio no recibe ningún certificado. La IA nunca elige uno por ti: una página que esté usando también te lo pregunta.
- **Certificados que no se pueden verificar.** Un sitio con un certificado autofirmado, de una CA privada en la que tu Mac no confía, caducado o de otro nombre muestra una advertencia dibujada por la propia app (nunca por la página), con el motivo y los detalles del certificado. «Visitar este sitio web» es pequeño, pide Touch ID o tu contraseña y deja pasar solo ese certificado para ese host y puerto hasta que cierres la app; si el certificado del sitio cambia, la advertencia vuelve. Mientras tanto la barra de direcciones muestra un aviso, y Ajustes del sitio tiene «Dejar de confiar en este certificado». Las páginas que usa la IA nunca reciben el camino para continuar. Los sitios de dominios que los navegadores saben que exigen HTTPS, y los certificados que eran correctos antes en esta sesión, no se pueden omitir.
- **Ventanas emergentes.** Las páginas no abren ventanas sin que se lo pidas. Las que se abren sin un clic se bloquean, con "Abrir" y "Permitir siempre en este sitio" justo encima de la página.
- **Rastreo fuera de los enlaces.** Los parámetros de rastreo conocidos (`utm_*`, `fbclid`, `gclid` y similares) se quitan de la dirección antes de cargar la página: en lo que escribes, en un marcador, en un enlace abierto en una pestaña nueva o en la vista previa y en lo que abre la IA. El resto de la dirección se queda como está. Los enlaces que pulsas dentro de una página, las redirecciones y los formularios se dejan como los escribió el sitio: WebKit no da a una app forma de cambiarlos sin perder lo que el sitio ve del origen del clic (cookies SameSite, `Referer`). Se desactiva en Ajustes › Privacidad, y un sitio donde algo falle tiene su propio interruptor en los ajustes del sitio.
- **Conexiones seguras primero.** Una dirección http que escribes, abres desde un marcador, abres en una pestaña nueva o en la vista previa, o que abre la IA, se prueba primero con https y se carga con http solo si nada responde por https (conexión rechazada, o tiempo agotado en lo que abres tú). Un certificado que no se puede verificar muestra el aviso de arriba y nunca se resuelve pasando a http. Los nombres que solo existen en una red local (un `router` sin punto, `.local`, `.test`, `localhost`), las direcciones IP y los puertos distintos de 80 se quedan como están, así que la página http de un router o un NAS se abre como antes; los ajustes del sitio dicen «Esta conexión no es segura» en una página http. Los enlaces pulsados dentro de una página, las redirecciones y los formularios se dejan como los hizo el sitio. Se desactiva en Ajustes › Privacidad.

El bloqueo de anuncios y rastreadores se explica en [Bloqueo de anuncios](#bloqueo-de-anuncios), y lo que se queda en tu Mac y lo que se envía, en [Privacidad](#privacidad).

### Guardar y descargas

- **Guardar una página.** Conserva una página para después como PDF o como imagen. Guárdala como un PDF largo de una sola hoja (Archivo › Guardar como PDF…) o como una imagen de la página entera, no solo de lo que se ve en pantalla (Archivo › Capturar página completa…). Ambas están también en el menú de una pestaña, se guardan en Descargas salvo que elijas otra carpeta y funcionan en ventanas privadas. Las páginas que se desplazan dentro de un panel interno y las imágenes que cargan al desplazarse pueden no capturarse por completo.
- **Descargas.** Mira cómo va una descarga, con una comprobación de seguridad la primera vez que se abre. Las descargas muestran su progreso en la parte inferior de la barra lateral y reciben la marca de cuarentena de Safari, así que Gatekeeper las comprueba la primera vez que se abren. Las apps, los scripts y los instaladores se muestran en el Finder en lugar de ejecutarse. Una descarga interrumpida continúa desde donde se quedó con Reintentar en su fila.
- **Zoom de página.** Ajusta el zoom de un sitio una vez y se queda así. El zoom de página se recuerda por sitio, así que solo tendrás que entrecerrar los ojos una vez.
- **Sesión guardada.** Hasta los navegadores se cierran de golpe. Las pestañas abiertas se guardan cada 15 segundos, así que un cierre inesperado cuesta casi nada.

### Actualizaciones

- **Actualizaciones automáticas.** Changmun se actualiza solo con Sparkle. Busca una vez al día en segundo plano y, cuando hay una versión nueva, te ofrece instalarla; Changmun › Buscar actualizaciones… busca al momento. Las actualizaciones van firmadas y Changmun solo instala una si la firma coincide con la clave incluida en la app. En Ajustes › Avanzado puedes desactivar la búsqueda automática o dejar que descargue e instale por su cuenta.

## IA

El panel de la derecha (⌘E) usa la CLI `claude` que ya tienes, así que funciona con tu suscripción a Claude Code. El modelo por defecto es Sonnet. El menú bajo el cuadro de mensaje (se lee como «Sonnet · Alto») fija el modelo y el esfuerzo (Automático, Bajo, Medio, Alto, Muy alto o Máximo, que se pasa a `--effort` de Claude Code; Automático no pasa nada). El modelo también se cambia en Ajustes › IA.

La cabecera del panel muestra el título del chat, que es su primer mensaje. Su menú lista los chats recientes y «Mostrar todos los chats»; al lado hay un botón de chat nuevo y otro que saca el panel a una ventana propia. Al cerrar esa ventana, el panel vuelve a la ventana del navegador. Las preguntas y las tarjetas de aprobación funcionan también ahí, y la ventana pasa al frente cuando la IA pregunta. Mientras trabaja, el panel muestra «Trabajando durante 12 s» con los pasos en directo debajo (se pueden desplegar). Tu mensaje lleva tarjetas de las páginas que fueron con él, cada una con su título y su sitio. Un pequeño anillo indica cuánto del contexto del modelo usa el chat (pasa el puntero para ver el porcentaje).

La IA maneja el navegador con estas herramientas: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `read_tabs`, `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover`, `drag`, `wait_for`, `scroll`, `screenshot`, `sign_in`. Los campos de contraseña, los códigos de un solo uso y los de tarjeta no puede leerlos ni rellenarlos ni pulsar teclas en ellos, y las capturas los ocultan. Tampoco puede subir archivos.

- `read_page` añade a cada elemento sus estados entre corchetes: `[checked]`/`[unchecked]`, `[selected]`, `[expanded]`/`[collapsed]`, `[disabled]`, `[focused]`, `[pressed]`, `[required]`, `[invalid]`. También muestra en una línea el valor actual de campos y listas, pero nunca el de contraseñas, códigos y tarjetas.
- Tras `click`, `click_at`, `type_text`, `press_key`, `select_option`, `hover` y `drag`, cuando la página se asienta (como mucho 1,5 segundos), la respuesta cuenta qué cambió desde la última vez que la IA la vio: dirección y título, elementos nuevos (`+`, con número a continuación, que se pueden usar de inmediato), cambiados (`~`) y desaparecidos (`-`). Hasta 40 líneas; si hubo una navegación, solo lo dice y recomienda `read_page`. Cuenta como una lectura. Un cambio solo del foco va al final y no cuenta en las 40 líneas; un frame que no responde se omite y se avisa; un elemento que vuelve (un menú que se abre otra vez) es nuevo de nuevo.
- `screenshot` con `labels` vuelve a leer la página y dibuja en la imagen un recuadro con el número de `read_page` de cada elemento a la vista. No se añade nada a la página: se dibuja solo en la imagen. Dónde caen los recuadros depende del diseño de la página; sobre los elementos manda lo que diga `read_page`. También sirve `changmun screenshot --labels`.
- Cada herramienta acepta un `title` opcional («Comparando precios») que aparece tal cual en la línea de progreso del panel; si no, el texto que genera Changmun. Es texto del modelo, así que se reduce a una línea de 60 caracteres y no interviene en ninguna pregunta ni decisión. El título va después del texto de Changmun («Pulsando «Comprar» · Comparando precios») y nunca lo sustituye; en `sign_in` y en lo que pregunta siempre solo se muestra el texto de Changmun.
- Mientras la IA trabaja, el campo sigue admitiendo mensajes. Intro pone uno en cola como una etiqueta y se envían en orden cuando la ejecución anterior termina bien (con las pestañas de cuando lo escribiste). Si la ejecución falla o se corta, las etiquetas se quedan y un botón «Enviar en cola» espera tu orden. ⌘Intro detiene la ejecución como Detener y continúa al instante, en la misma conversación, con el mensaje nuevo. Detener y Nuevo chat vacían la cola. Esperan como mucho 8 mensajes (una línea avisa si hay más); un segundo ⌘Return mientras espera se suma al primero; si la conversación no se puede reanudar tras la interrupción, el mensaje se envía de nuevo como conversación nueva y el panel lo dice. Con métodos de entrada (coreano, japonés, chino) Return pertenece al método mientras se compone texto.
- `sign_in` rellena tu acceso guardado en el formulario sin que la IA lo vea. El host exacto de la página debe ser el del acceso guardado (solo https) y no funciona en ventanas privadas. Cada vez pregunta «¿Dejar que la IA inicie sesión en … como …?» y lo confirmas con Touch ID o la contraseña del Mac (con varias cuentas, eliges una en la ventana). Si no hay un acceso guardado, dices que no, no respondes o no confirmas, la IA oye siempre lo mismo, «No se inició sesión», así que no puede averiguar qué cuentas tienes. La IA no recibe ni la contraseña ni el nombre de la cuenta. No pulsa nada: el clic siguiente lo da la IA y se juzga como cualquier otro. Sin acceso guardado también ves una ventana (solo para cerrarla) y la IA espera lo mismo; tras rechazar un sitio, en el mismo chat no hay ventana pero sí una espera fija de cuatro segundos y una línea en el panel. Se rechazan formularios cuya acción o cuyo botón de envío (esté donde esté) vayan a otro sitio.

Para trabajar con varias pestañas, añádelas desde el menú + del cuadro de mensaje con «Añadir pestaña…» (una a una, un grupo de pestañas o todas las abiertas): aparecen como etiquetas que puedes quitar, la IA las lee juntas con `read_tabs` y no te pregunta antes de leerlas. Con dos o más añadidas, el panel sugiere compararlas o resumir lo esencial de cada una.

La pestaña que ve la IA aparece como una etiqueta en la fila bajo el chat, y al escribir @ en el cuadro puedes adjuntar otra. ⌘E lleva el cursor al cuadro (desde el cuadro, cierra el panel), Esc detiene la ejecución (el botón Detener del cuadro de mensaje también), ↑ recupera tu último mensaje y el borde izquierdo del panel se arrastra para cambiar su ancho. Las sugerencias se ajustan a la página en la que estás, y «Preguntar a la IA sobre la selección», en el menú contextual de la página, cita el texto seleccionado en el cuadro.

Las respuestas muestran bloques de código, listas y tablas, con botón de copiar en el código. Un enlace dice también a qué sitio va de verdad, y cuando el chat ha leído otros sitios, abrir un enlace de una respuesta pregunta antes. Una tarea larga se pliega en «12 pasos» con una línea de cuántas pestañas abrió y cerró, y «Volver a abrir» recupera las que cerró. Si Claude Code no tiene la sesión iniciada, se agotó su límite de uso o fallan la red o los servidores de Anthropic, el panel lo dice con claridad y ofrece «Reintentar».

En el menú +, «Adjuntar captura» adjunta una imagen de la página en la que estás (lo secreto de la página queda fuera) y «Añadir imagen…» añade una de tu Mac. También puedes soltar o pegar imágenes en el panel: hasta 4 por mensaje, reducidas a 1568 píxeles en el lado largo y guardadas de nuevo sin el lugar ni la hora que llevaba el archivo. Una imagen cuenta como algo que la IA ha leído (una captura, como su página; cualquier otra, como una imagen añadida por ti), así que lo que haga después se pregunta igual que tras leer otro sitio. El botón del micrófono inicia el dictado de macOS.

Los chats terminados se guardan solo en este Mac y puedes releerlos desde el menú de chats de la cabecera del panel («Mostrar todos los chats»). Son de solo lectura (un chat no se retoma: la IA seguiría recordando las páginas que leyó, pero Changmun ya no sabría de qué sitios eran y se saltaría la pregunta de tras leer otros sitios), y las ventanas privadas nunca se registran. Lo que se escribió o eligió se guarda solo como longitud, y las direcciones pierden lo que sigue a ? o #. Se desactiva en Ajustes › IA › Conservar el historial de chats, y puedes borrar un chat o todos desde el panel.

Para que unas instrucciones ocultas en una página no puedan hacer que lleve a otro sitio lo que ha leído, Changmun te pregunta primero. Cuánto pregunta lo eliges entre tres opciones, en el menú de aprobaciones bajo el cuadro de mensaje o en Ajustes › IA (sustituyen al antiguo interruptor, y tu ajuste actual se conserva):

- **Preguntar tras leer otros sitios** (por defecto). Las preguntas de la lista siguiente.
- **Preguntar antes de cada acción.** Pregunta también antes de escribir, elegir o hacer clic en una página aunque el chat no haya leído otros sitios. Puedes permitir un sitio hasta que acabe el chat.
- **Preguntar solo por acciones que no se pueden deshacer.** Se salta las tres primeras preguntas de la lista siguiente y mantiene las dos últimas.

Sin respuesta en 90 segundos cuenta como no. Las tres primeras preguntas de la lista son las del modo por defecto; las dos últimas se hacen en todos los modos. Changmun pregunta:

- antes de que use una pestaña que no estás mirando, una vez por pestaña y sitio;
- antes de que abra una dirección, salvo que sea una búsqueda, una dirección ya abierta, visitada o guardada en marcadores, o la página principal de un sitio conocido;
- antes de cada clic, tecla, paso del puntero, arrastre, texto escrito u opción elegida una vez que el chat ha leído otro sitio, mostrándote lo que va a hacer. Puedes permitirlo solo esta vez o en ese sitio hasta que acabe el chat. No preguntan el desplazamiento, mirar la página en primer plano (leer, captura, esperar, lista de pestañas) ni ir atrás, adelante o recargar. Un chat nuevo (⌘⇧E) empieza de cero.
- antes de lo que parece pagar, pedir, enviar, publicar, comentar, compartir, subir, dar acceso (permitir, conectar, autorizar), borrar, cancelar o darse de baja, siempre, aunque hayas permitido lo demás (solo «permitir una vez» o «no permitir»). Lo mismo para Intro en un cuadro de mensaje, un formulario que envía a otro sitio y Supr o Retroceso fuera de un campo de texto.
- antes de lo que parece aceptar o permitir en un aviso de cookies, o cambiar un ajuste (guardar, borrar, restablecer, bloquear), una vez por sitio. En el panel de IA puedes permitirlo en ese sitio hasta que acabe el chat, y a un cliente MCP mientras dure su conexión (hasta que termine esa sesión de Claude Code, es decir, su servidor MCP); a la línea de comandos se le pregunta cada vez.

Dentro del panel, las preguntas de la IA salen como una tarjeta sobre el cuadro de mensaje, no como una ventana sobre la página. Return o Esc es «No permitir», ⌘Return es «Permitir una vez» y ⌥⌘Return permite ese sitio en este chat. Las teclas que dicen sí solo funcionan con el cursor dentro del panel y pasado medio segundo desde que sale la tarjeta, para que una pulsación pensada para otra cosa no responda. Las preguntas sobre pagar, borrar o iniciar sesión, y sobre un botón que solo el marcado de la página llama aviso de cookies, siguen saliendo en una ventana, donde ninguna tecla dice sí. La cabecera del panel dice lo que ha leído el chat («3 sitios leídos · Permitido en 1») y lista los sitios que permitiste, cada uno con «Revocar».

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
changmun read-tabs 3 5
changmun click 12
changmun type 3 "hello" --submit
```

`changmun help` muestra el resto. Cada orden es una de las mismas herramientas, con las mismas preguntas, y abre Changmun si hace falta.

### Changmun sin interfaz, para agentes

Que un agente te haga las mismas preguntas en el navegador que estás usando cansa enseguida. Para los agentes hay un segundo Changmun sin ventana: invisible, sin tomar el foco ni hacer ruido, con un perfil propio, así que no tiene ninguna de tus cookies, historial, contraseñas ni el llavero.

```sh
changmun headless start     # copia la app desde la que lo ejecutas en ~/Library/Application Support/Changmun Agent y la inicia
changmun headless status    # si está en marcha, pid, versión, carpeta del perfil
changmun --headless open example.com
changmun --headless read
changmun headless stop
claude mcp add changmun-headless -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp --headless
```

Pon `--headless` en cualquier comando para mandarlo allí en vez de a tu navegador; `--mcp --headless` es la forma MCP. Ambos lo inician si no está en marcha. Aquí no se pregunta antes de que la IA use otras pestañas, abra direcciones nuevas o actúe tras leer otros sitios: esas preguntas, que protegen de instrucciones escondidas en las páginas, están desactivadas. Por eso es una copia aparte con un perfil vacío, y por eso rechaza lo que no se puede deshacer: lo que parezca pagar, pedir, enviar, publicar, borrar o conceder acceso, y cualquier cosa dentro de lo que una página solo llama banner de cookies, recibe un error de "hace falta una persona", porque nadie está mirando y un sitio en el que inicies sesión ahí dentro quedaría a disposición de la IA. Todo lo demás se permite. Los permisos de sitios (cámara, ubicación…) se deniegan. La copia se hace a partir de la app que ejecuta el comando y se rehace cuando es otra versión (`changmun headless status` te lo dice); nunca se actualiza sola. La copia para agentes no conserva sesiones: su interruptor está desactivado y no guarda ninguna clave en tu Llavero.

## Atajos

Elige estilo Safari o estilo Chrome en Ajustes (⌘,). Solo cambian las teclas en las que los dos navegadores discrepan.

| Teclas | Acción |
| --- | --- |
| ⌘T / ⌘L | Barra de comandos / editar la dirección actual |
| ⌘E / ⌘⇧E | Panel de IA / nuevo chat de IA |
| ⌘D | Añadir o quitar un favorito |
| ⇧⌘D | Añadir la página a la lista de lectura |
| ⌘N / ⌘⇧N / ⌘⇧W | Nueva ventana / nueva ventana privada / cerrar ventana |
| ⌘W, ⌘1–9, ⌘⇧[ ⌘⇧] | Cerrar pestaña, ir a una pestaña según el orden de la barra lateral |
| ⌃Tab / ⌃⇧Tab | Cambiar de pestaña en el orden en que las viste por última vez (mantén ⌃, pulsa Tab, suelta; esc cancela) |
| ⌃1–9 | Ir a un espacio (9 es el último); cede ante «Cambiar al escritorio N» de macOS si lo tienes activado |
| ⌃⌥← / ⌃⌥→ | Espacio anterior / siguiente |
| ⌃⌘N | Nuevo espacio |
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

## Bloqueo de anuncios

Changmun convierte EasyList (anuncios) y EasyPrivacy (rastreadores) en reglas de bloqueo de contenido de WebKit y las actualiza cada 4 días. En Ajustes › Privacidad puedes desactivar listas o añadir otras por su dirección (una lista de anuncios coreana está a un clic). Si un sitio se rompe, el escudo de la barra de direcciones desactiva el bloqueo para ese sitio. Las reglas que WebKit no puede expresar (expresiones regulares, `$redirect`, scriptlets, `:has-text` y otros selectores extendidos) se omiten en lugar de adivinarse: es mejor perder un anuncio que romper una página.

## Extensiones

Se gestionan en Ajustes › Extensiones (las extensiones web requieren macOS 15.4 o posterior).

En las pestañas de un espacio con perfil las extensiones funcionan, pero sus API de cookies solo ven el almacén de datos predeterminado, no el del perfil.

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
- La búsqueda de actualizaciones descarga de GitHub Pages una pequeña lista de versiones (`appcast.xml`). GitHub recibe la petición como cualquier servidor web, con el nombre y la versión de Changmun; el perfil del sistema de Sparkle, que añadiría datos de tu Mac, está desactivado y sigue así (Ajustes › Avanzado desactiva la búsqueda).
- Las sugerencias de búsqueda envían a tu buscador lo que escribes en la barra de comandos (desactívalas en Ajustes; nunca se envían desde ventanas privadas).
- «Mantener la sesión al salir» (Ajustes › Privacidad, activado de serie) conserva, hasta 30 días, las cookies de inicio de sesión que los sitios querían borrar al cerrar el navegador (solo las de sesión; las demás las guarda WebKit). Se guardan en un archivo de este Mac, cifrado con una clave de tu llavero de inicio de sesión que solo la firma de código de Changmun puede leer sin preguntar, hasta que lo desactives o borres los datos de sitios; las ventanas privadas nunca guardan nada. La copia para agentes de más arriba no conserva sesiones.
- El panel de IA envía tus mensajes, las imágenes que adjuntas y el contenido de las páginas que lee la IA, a Anthropic a través de la CLI `claude`. Ordenar pestañas y la traducción de páginas se ejecutan en tu Mac.

## Contraseñas y seguridad

A los navegadores que sincronizan contraseñas se les hace una pregunta razonable: si una copia cifrada de mis contraseñas está en vuestro servidor, ¿podéis descifrarla, iniciar sesión como yo o venderla si la empresa quiebra? En Changmun las respuestas son cortas, y cada una se comprobó en el código.

- **Dónde están.** En el llavero de inicio de sesión de tu Mac, como contraseñas de internet con la etiqueta `Changmun` (búscala en Acceso a Llaveros). Changmun no las marca como sincronizables, así que el llavero de iCloud tampoco las lleva a ningún sitio. Si borras una en Ajustes › Privacidad › Contraseñas guardadas › Gestionar…, desaparece del llavero.
- **No hay copia en ningún otro sitio.** Changmun no tiene cuentas ni servidor, así que no existe una copia cifrada que descifrar, vender, filtrar o heredar. Además de las peticiones que figuran en Privacidad, lo único que la app descarga por su cuenta son las listas de filtros de anuncios, una extensión de Chrome Web Store que hayas pedido y el icono de cada sitio, directamente de ese sitio. Ninguna lleva una contraseña.
- **Quién puede descifrarlas.** Solo este Mac, una vez que lo has desbloqueado. Se pide Touch ID o la contraseña de tu Mac antes de copiar una contraseña, antes de rellenarla en una página (Ajustes › Privacidad › Pedir Touch ID para rellenar contraseñas, activado por defecto; tras confirmar, los rellenados del minuto siguiente no vuelven a preguntar) y antes de que la IA inicie sesión por ti. Si cancelas, no se rellena nada.
- **La IA nunca las recibe.** Con `sign_in`, Changmun rellena el formulario por sí mismo y solo le dice a la IA que lo hizo, sin la contraseña ni el nombre de la cuenta. La IA no puede leer los campos de contraseña, escribir en ellos ni pulsar teclas en ellos, y las capturas los ocultan. Si luego lee la página ya con la sesión iniciada, el texto de esa página es contenido de página como cualquier otro.
- **Qué llega a Anthropic.** Tus mensajes, las imágenes que adjuntas y las páginas que lee la IA, a través de tu propia CLI `claude`, y nada más. Changmun no tiene ninguna clave de Anthropic ni hace peticiones a Anthropic por su cuenta.
- **Historial de chats.** Los chats terminados quedan en un archivo de este Mac (Ajustes › IA lo desactiva), sin el texto escrito ni lo que sigue a ? o # en las direcciones, y nunca los de una ventana privada.
- **Contraseñas importadas.** Se descifran en tu Mac con la clave `Safe Storage` del llavero de cada navegador (macOS pregunta antes) y se guardan en tu llavero de inicio de sesión. No se sube nada por el camino.
- **Si el proyecto se para.** No hay nada que vender ni que apagar: ni servidor, ni cuentas, ni la base de datos de nadie. Tus contraseñas siguen en tu llavero y la app sigue funcionando mientras funcione macOS. Es de código abierto con licencia MIT, así que cualquiera puede comprobar todo esto, empezando por `Sources/Changmun/Tabs/Logins.swift`.

## Para desarrolladores

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

Las versiones se firman para Sparkle con una clave EdDSA. Pon la ruta del archivo de la clave privada en `~/.config/changmun/sparkle.env` como `SPARKLE_KEY_FILE=...`; `release.sh` no se ejecuta sin ella, ni con una clave que no sea el `SUPublicEDKey` de `Resources/Info.plist`. Guarda una copia de ese archivo sin conexión. Si se pierde, las copias instaladas ya no podrán actualizarse nunca; si se filtra, cualquiera podrá firmar una actualización que aceptarán.

El texto de la interfaz está en inglés en el código y traducido en `Resources/<language>.lproj/Localizable.strings`; añade cada cadena nueva a las seis tablas.

`scripts/headless.sh` ejecuta la copia de pruebas, `Changmun Headless.app` (nunca comparte perfil con el `changmun headless` de la sección de IA, que es el de los agentes), un Changmun sin interfaz para pruebas y agentes: fuera de pantalla, sin tomar nunca el foco ni reproducir sonido, con su propio perfil en `~/Library/Application Support/Changmun Headless`. No toca el llavero, y responde por sí solo a las confirmaciones de la IA, los permisos de sitios y los diálogos de JavaScript (los permisos se deniegan).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## Licencia

[MIT](LICENSE)
