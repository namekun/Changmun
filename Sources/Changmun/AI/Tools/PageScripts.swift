import Foundation

/// Scripts run in an isolated JavaScript world: they share the page's DOM but not its variables.
enum PageScripts {
    static let readText = """
    const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n');
    const cut = text.length > maxChars ? text.slice(0, maxChars) + '\\n…(truncated)' : text;
    return 'Title: ' + document.title + '\\nURL: ' + location.href + '\\n\\n' + cut;
    """

    static let scroll = """
    const height = document.documentElement.scrollHeight;
    if (direction === 'top') scrollTo(0, 0);
    else if (direction === 'bottom') scrollTo(0, height);
    else scrollBy(0, (direction === 'up' ? -1 : 1) * innerHeight * 0.85);
    return 'Scrolled ' + direction + '. Now at ' + Math.round(scrollY) + ' of ' + height + ' (viewport ' + innerHeight + ').';
    """
}
