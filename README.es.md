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

*Changmun* (창문) significa *ventana* en coreano. Es gratuito, de código abierto y no necesita cuenta. La app está disponible en inglés, coreano, japonés, chino simplificado, español, alemán y francés.

## Instalar

```sh
brew install --cask namekun/tap/changmun
```

O [descarga la app](https://github.com/namekun/Changmun/releases/latest/download/Changmun.dmg) directamente.

- Necesita macOS 14 o posterior en un Mac con Apple silicon.
- Está firmada y notarizada por Apple, así que se abre sin problemas.
- Se actualiza sola.
- La primera vez que la abres, te ofrece traer tus marcadores y tu historial.

## Por qué Changmun

- **Ligero.** Una app de 21 MB, con una descarga de unos 7 MB. Usa el motor WebKit que ya tiene tu Mac.
- **Una barra lateral.** Pestañas verticales, favoritos, carpetas de marcadores, grupos de pestañas y espacios en una sola columna. ¿Prefieres las pestañas arriba? Es un ajuste.
- **Una IA que usa el navegador.** Claude lee páginas, hace clic y escribe por ti, y pregunta antes de hacer algo arriesgado.
- **Privado.** Sin cuenta, sin servidor, sin analíticas. Los anuncios y los rastreadores se bloquean desde el primer momento.
- **Tus cosas te acompañan.** Importa marcadores e historial de Safari y de los navegadores Chromium, y las contraseñas de estos últimos.
- **Una página de inicio propia.** Tres estilos, secciones que puedes ordenar a tu gusto y tu propio fondo.

## La IA

Pulsa ⌘E y pide lo que quieras con tus palabras:

- «Resume esta página.»
- «Compara los precios de estas tres pestañas.»
- «Inicia sesión en este sitio por mí.»

Funciona con la CLI `claude` que ya tienes, así que usa tu propia suscripción a Claude Code. Si no usas Claude, puedes ignorar el panel: el resto del navegador funciona sin él.

**Qué la mantiene a raya**

- Pregunta antes de pagar, enviar, publicar o borrar.
- Pregunta antes de usar una pestaña que no estás mirando o de abrir un sitio desconocido.
- No puede ver las contraseñas y nunca ve las ventanas privadas.

Tus mensajes, las imágenes que adjuntas y las páginas que lee van a Anthropic a través de la CLI `claude`. Otras herramientas también pueden manejar Changmun, mediante MCP o el comando `changmun`.

## Modo sin interfaz

Un segundo Changmun sin ventana, para agentes de IA y scripts. No se ve, no toma el foco y no hace ruido.

```sh
changmun headless start
changmun --headless open example.com
changmun --headless read
changmun headless stop
```

Para dárselo a Claude Code:

```sh
claude mcp add changmun-headless -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp --headless
```

- **Separado de ti.** Tiene su propio perfil vacío, así que no contiene tus cookies, historial, contraseñas ni Llavero.
- **Sin preguntas.** Las aprobaciones habituales están desactivadas, así que un agente puede trabajar sin detenerse a preguntar.
- **Se detiene ante lo que no se puede deshacer.** Lo que parezca pagar, pedir, enviar, publicar, borrar o dar acceso recibe un error de "hace falta una persona".

[Más sobre el modo sin interfaz](GUIDE.es.md#changmun-sin-interfaz-para-agentes)

## Comparación con otros navegadores

Changmun no intenta ganar a todos los navegadores en todo. Aquí ves en qué se diferencia y cuándo te conviene más otro.

| | Tamaño de la app | Motor |
| :-- | --: | :-- |
| **Changmun 0.10.2** | **21 MB** | WebKit, el de macOS |
| Safari 27 | 35 MB | WebKit, el de macOS |
| Google Chrome 156 | 731 MB | Chromium, copia propia |
| Arc 1.168 | 862 MB | Chromium, copia propia |
| Dia 1.53 | 1,3 GB | Chromium, copia propia |

<sub>Medido con `du -sh` en un Mac con Apple silicon en octubre de 2026.</sub>

| Frente a | Lo que te da Changmun | Sigue con el otro si necesitas |
| :-- | :-- | :-- |
| **Safari** | El mismo motor, más una barra lateral con pestañas verticales, una IA que puede manejar una página y extensiones de Chrome Web Store | La sincronización de iCloud de pestañas, contraseñas y llaves de acceso |
| **Chrome** | Sin cuenta de Google ni servidor de sincronización, y una app de alrededor del 3 % de su tamaño | Sitios hechos solo para Chromium, la sincronización de Chrome, o Windows, Linux y el móvil |
| **Arc** | La misma idea de barra lateral y espacios, y sigue ganando funciones (Arc está en modo de mantenimiento desde mayo de 2025) | Boosts o Easels |
| **Dia** | La misma familia de ideas, sin servicio de IA propio y sin cuenta: usa tu CLI `claude` | Sus funciones de IA alojadas y sus integraciones de trabajo |

Esto sale de lo que cada proyecto dice de sí mismo. Si algo está desactualizado, [abre un issue](https://github.com/namekun/Changmun/issues).

### Lo que aún falta

- **Sin sincronización.** Los marcadores, el historial y las contraseñas se quedan en el Mac donde se crearon.
- **Solo Mac.** Ni iPhone, ni Windows, ni Linux.
- **Aún sin llaves de acceso.** Los navegadores necesitan un permiso (entitlement) de Apple; Changmun lo ha pedido y está esperando.
- **Las extensiones necesitan macOS 15.4 o posterior,** y algunas extensiones de Chrome dependen de cosas que WebKit no tiene.
- **Los sitios hechos solo para Chromium** pueden fallar aquí, como pueden fallar en Safari.
- **Un solo mantenedor.** Menos ojos que los grandes navegadores y, con ellos, asperezas. Los informes de errores son bienvenidos.

## Atajos que conviene conocer

| Teclas | Qué hace |
| :-- | :-- |
| ⌘T | Pestaña nueva |
| ⌘L | Editar la dirección |
| ⌘E | Panel de IA |
| ⌘D | Añadir o quitar un favorito |
| ⌃1–9 | Ir a un espacio |
| ⌥⌘\\ | Vista dividida |
| ⇧-clic en un enlace | Previsualizarlo sin salir de la página |
| ⌘⇧T | Reabrir una pestaña cerrada |

¿Teclas al estilo Safari o al estilo Chrome? Elige en Ajustes (⌘,). [Todos los atajos](GUIDE.es.md#atajos).

## Privacidad

Lo que haces en la web se queda en tu Mac. La app solo hace unas pocas peticiones por su cuenta, como buscar actualizaciones y renovar las listas de filtros de anuncios. Las sugerencias de búsqueda envían lo que escribes a tu buscador; puedes desactivarlas, y las ventanas privadas nunca las envían. [Todo lo que se envía, y cuándo](GUIDE.es.md#privacidad).

## Saber más

La [guía](GUIDE.es.md) lo cuenta todo con detalle:

- [Funciones](GUIDE.es.md#qué-hace): pestañas, espacios, modo lectura, ventanas privadas, descargas
- [IA](GUIDE.es.md#ia): modelos, aprobaciones, herramientas, MCP y la línea de comandos
- [Bloqueo de anuncios](GUIDE.es.md#bloqueo-de-anuncios), [extensiones](GUIDE.es.md#extensiones) e [importar desde otros navegadores](GUIDE.es.md#importar-desde-otros-navegadores)
- [Contraseñas y seguridad](GUIDE.es.md#contraseñas-y-seguridad)
- [Para desarrolladores](GUIDE.es.md#para-desarrolladores) y [compilar desde el código fuente](GUIDE.es.md#compilar-desde-el-código-fuente)

## Licencia

MIT. Consulta [LICENSE](LICENSE).
