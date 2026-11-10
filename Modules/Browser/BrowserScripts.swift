import Foundation

/// The scripts Kiln runs inside a page. They run in a separate content world, so page scripts cannot
/// replace the functions they use, and every argument is passed as data rather than spliced into the source.
enum BrowserScripts {
    static let maxTextCharacters = 20_000
    static let maxOutlineItems = 250

    /// Visible text, title and address.
    static let readText = """
    const limit = maxChars;
    const text = (document.body ? document.body.innerText : '') || '';
    return JSON.stringify({
        title: document.title || '',
        url: location.href,
        text: text.length > limit ? text.slice(0, limit) : text,
        truncated: text.length > limit,
        length: text.length
    });
    """

    /// An accessibility-style outline: headings, landmarks and everything you could click or type into,
    /// each interactive element numbered with a `ref` that `click` and `type` accept. Password values are
    /// never reported.
    static let outline = """
    document.querySelectorAll('[data-kiln-ref]').forEach(e => e.removeAttribute('data-kiln-ref'));
    const visible = (e) => {
        const r = e.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return false;
        const s = getComputedStyle(e);
        return s.visibility !== 'hidden' && s.display !== 'none';
    };
    const clean = (t) => (t || '').replace(/\\s+/g, ' ').trim().slice(0, 100);
    const sensitive = (e) => {
        const t = (e.getAttribute('type') || '').toLowerCase();
        const ac = (e.getAttribute('autocomplete') || '').toLowerCase();
        return t === 'password' || ac.includes('password') || ac.startsWith('cc-') || ac.includes('one-time-code');
    };
    const labelOf = (e) => {
        if (e.getAttribute('aria-label')) return clean(e.getAttribute('aria-label'));
        if (e.id) { const l = document.querySelector('label[for="' + CSS.escape(e.id) + '"]'); if (l) return clean(l.innerText); }
        const wrap = e.closest('label'); if (wrap) return clean(wrap.innerText);
        const text = (e.matches('input,textarea,[contenteditable]') ? '' : e.innerText);
        return clean(text || e.getAttribute('placeholder') || e.getAttribute('title') || e.alt || '');
    };
    const selector = 'h1,h2,h3,h4,h5,h6,a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=textbox],[role=checkbox],[role=tab],[role=menuitem],nav,main,form,[role=search]';
    const lines = [];
    let ref = 0, count = 0;
    for (const e of document.querySelectorAll(selector)) {
        if (count >= maxItems) { lines.push('… outline truncated'); break; }
        if (!visible(e)) continue;
        const tag = e.tagName.toLowerCase();
        const role = e.getAttribute('role');
        if (/^h[1-6]$/.test(tag)) { lines.push('#'.repeat(Number(tag[1])) + ' ' + clean(e.innerText)); count++; continue; }
        if (tag === 'nav' || tag === 'main' || tag === 'form' || role === 'search') { lines.push('<' + (role || tag) + '>'); continue; }
        if (tag === 'input' && (e.type || '').toLowerCase() === 'hidden') continue;
        ref += 1; e.setAttribute('data-kiln-ref', String(ref)); count++;
        let kind = role || tag, extra = '';
        if (tag === 'a') { kind = 'link'; extra = ' → ' + (e.href || ''); }
        else if (tag === 'input') {
            const type = (e.type || 'text').toLowerCase();
            kind = ['button','submit','reset','image'].includes(type) ? 'button' : (['checkbox','radio'].includes(type) ? type : 'textbox');
            extra = ' (type=' + type + (sensitive(e) ? ', sensitive: Kiln will not type here' : '') + ')';
            if (type === 'checkbox' || type === 'radio') extra += e.checked ? ' [checked]' : ' [unchecked]';
        } else if (tag === 'textarea') { kind = 'textbox'; }
        else if (tag === 'select') { kind = 'combobox'; extra = ' value="' + clean(e.options[e.selectedIndex] ? e.options[e.selectedIndex].text : '') + '"'; }
        if (e.disabled) extra += ' [disabled]';
        lines.push('[' + ref + '] ' + kind + ' "' + labelOf(e) + '"' + extra);
    }
    return JSON.stringify({ title: document.title || '', url: location.href, outline: lines.join('\\n') });
    """

    static let click = """
    const e = document.querySelector('[data-kiln-ref="' + String(ref) + '"]');
    if (!e) return JSON.stringify({ ok: false, error: 'No element with ref ' + ref + '. Read the page again (browser_read_page) for current refs.' });
    if (e.disabled) return JSON.stringify({ ok: false, error: 'Element ' + ref + ' is disabled.' });
    e.scrollIntoView({ block: 'center', inline: 'center' });
    const text = e.matches('input,textarea,[contenteditable]') ? '' : e.innerText;
    const what = (e.tagName.toLowerCase() + ' "' + (e.getAttribute('aria-label') || text || '').replace(/\\s+/g, ' ').trim().slice(0, 80) + '"');
    e.click();
    return JSON.stringify({ ok: true, clicked: what });
    """

    /// Refuses credential fields outright: a password, card number or one-time code is typed by the user.
    static let type = """
    const e = document.querySelector('[data-kiln-ref="' + String(ref) + '"]');
    if (!e) return JSON.stringify({ ok: false, error: 'No element with ref ' + ref + '. Read the page again (browser_read_page) for current refs.' });
    const tag = e.tagName.toLowerCase();
    if (tag !== 'input' && tag !== 'textarea' && !e.isContentEditable) return JSON.stringify({ ok: false, error: 'Element ' + ref + ' is not a text field.' });
    const t = (e.getAttribute('type') || 'text').toLowerCase();
    const ac = (e.getAttribute('autocomplete') || '').toLowerCase();
    const hint = ((e.name || '') + ' ' + (e.id || '')).toLowerCase();
    if (t === 'password' || ac.includes('password') || ac.startsWith('cc-') || ac.includes('one-time-code') || /pass(word)?|pwd|cvv|cvc|card.?num|ssn/.test(hint))
        return JSON.stringify({ ok: false, error: 'Refused: this looks like a credential or payment field. Kiln never types passwords, card numbers or codes; ask the user to enter it.' });
    if (['checkbox','radio','file','button','submit','reset','image'].includes(t)) return JSON.stringify({ ok: false, error: 'Element ' + ref + ' is a ' + t + ' control; use browser_click.' });
    e.scrollIntoView({ block: 'center' });
    e.focus();
    if (e.isContentEditable) { e.textContent = text; }
    else {
        const proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, text);
    }
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
    let submitted = false;
    if (submit && e.form) { if (e.form.requestSubmit) e.form.requestSubmit(); else e.form.submit(); submitted = true; }
    return JSON.stringify({ ok: true, typed: text.length, submitted: submitted });
    """
}
