# Translating the summary

Start with [translation-template.html](translation-template.html), a short English summary with the same scope as [ja.html](ja.html). The full [English page](index.html) is the source of truth. Check it before translating: the template is a dated starting point, not an automatically updated source.

Each translation is a separate, reviewed HTML page. It shares `checker.js` with the English page, so the host list and test logic stay together. No build step is needed. Local translation tools are fine; commit the resulting HTML so reviewers can read exactly what will be published.

## Make a copy

Work from the latest `main`, then copy the template into the repository root. For example, for French:

```sh
git switch -c french-summary
cp translation-template.html fr.html
```

In your copy:

- Delete the template comment at the top of the file.
- Change the document's `<html lang="en">` to the language tag, such as `fr` or `pt-BR`. Add `dir="rtl"` for a right-to-left language. Keep the English credit paragraph marked `lang="en" dir="ltr"`.
- Replace every `LANGUAGE_NAME`, `TRANSLATOR_NAME` and `SOURCE_DATE`. Name the language in its own language, credit yourself, and give the date on which you checked the English source. Keep the English credit paragraph readable in English too. The article's **20 October 2026** date is separate from your translation's review date.
- Translate the title, description, headings, prose, table headings, the table region's `aria-label`, button, draft notice, no-JavaScript note and values in `window.CHECKER_STRINGS`.
- Replace the comment in `<head>` about the canonical URL with the page's canonical URL and its language alternate. For French:

  ```html
  <link rel="canonical" href="https://emudhra.we-have-a-problem.com/fr.html">
  <link rel="alternate" hreflang="fr" href="https://emudhra.we-have-a-problem.com/fr.html">
  ```

Keep the draft label and `noindex, nofollow` while the translation is being reviewed, and agree their removal with the maintainer. When the translation is published, add its language alternate to `index.html` and every other translation, such as `ja.html`, so that each page lists all of them, and agree with the maintainer how the English page links to it. The English page sends browsers whose first preferred language is Japanese to `ja.html`. The same can be proposed for your language once the translation is published, but never for a draft.

Keep `?lang=en` on the `English` link next to the language name. It records that the reader chose English, so the English page no longer sends them to a translation. Other links to the English page do not need it.

## Preserve the meaning

Use natural language for general readers while preserving the English facts, dates, scope and degree of certainty. Keep the summary short and link to the English sections for changing patch lists and workarounds. If the English needs a factual correction or more explanation, propose a small follow-up PR updating it and the affected translation.

- A **client** can be a browser, command-line tool or application. The page's test checks only the current browser. Updating the browser or OS may not update applications with their own CA bundles.
- A **root program** decides which CAs a vendor trusts. A **trust store** is the list of trusted roots used for certificate verification. Explain these terms briefly if readers will not know them.
- **❌ Insecure** means a test connection succeeded. **✅ Did not connect** means only that it failed; page JavaScript cannot distinguish certificate rejection from a network error. **⚠️ Inconclusive** covers timeouts, unexpected responses and reported offline failures. Preserve the symbols and the `.good`, `.bad` and `.pending` colours.
- **No CT** means the leaf certificate was never logged to Certificate Transparency. A client can reject it because it requires CT while still trusting the compromised intermediate. Keep the label and translate its `noctTitle` explanation.
- Keep certificate names, hostnames, URLs, commands, versions and signed messages unchanged. Preserve `translate="no"` wherever it occurs. Link to the current English workarounds rather than copying commands that change a trust store into the summary.

In the checker strings, translate only the text. Keep the property names, arguments (`status`, `n`, `total`, `unknown`), `${...}` expressions, JavaScript quotes and operators intact. Most strings are in single quotes, so write an apostrophe inside them as `\'` or use the typographic ’. An unescaped quote breaks the whole script, and the checker then shows English with no error on the page. All current strings are included in the template; an omitted key falls back to English. Compare them with the defaults in `checker.js` when revising a translation.

Keep `results`, `rerun`, `summary`, the empty table body and `<script src="checker.js" defer></script>`. The shared checker supplies the certificate names and test rows; do not copy its host list into the translation.

## Preview and submit

From the repository root, run:

```sh
python3 -m http.server 8000 --bind 127.0.0.1
```

Open `http://127.0.0.1:8000/fr.html` (using your filename). Scroll to the table to start the check. Browser trust and network conditions affect live results; a green result alone does not establish why a request failed.

Before opening the PR:

- Read the copy against the current English page. Check names, dates, links, emphasis, the translation credit and source date. Search for leftover `LANGUAGE_NAME`, `TRANSLATOR_NAME` and `SOURCE_DATE` placeholders, and check that both template comments about the copy and the canonical URL are gone.
- Check a wide window and a narrow phone-sized window, including the result table. For RTL languages, check the text direction and certificate names as well.
- Confirm that the table fills with your translated text rather than English, the summary appears and the button becomes available again after the run and cooldown. Check the browser console for JavaScript errors.
- With the page already loaded, use the browser developer tools to simulate offline mode and rerun: failed rows should show ⚠️, and the summary should warn that results may be invalid. Return to online mode afterwards.
- Disable JavaScript and reload: the summary, English links and no-JavaScript note should remain readable.

Keep the PR focused on one language. Include the following information in its description:

```text
Language and filename:
Translator:
English source commit and date checked:
Any departures from the English summary:
Checks performed (layout, checker, offline, no JavaScript):
Can you help review updates to this translation for a while?
```

## Keep it current

English updates can ship while translations catch up. When editing the English page or `checker.js`, note any affected summary passages or new checker strings so translation volunteers can review them. Update the English template where its content is affected too. Keep the latest-English link and the last-checked date on every translation; advance that date only after reviewing the source again. If you can no longer help maintain a translation, say so in the repository so another volunteer can take over.
