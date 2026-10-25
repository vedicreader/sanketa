import Foundation

/// The prompt texts of `.superpowers/pack-maker/prompt-template.md`. `PackMaker` fills the `{{…}}` placeholders.
public extension PackMaker {
    /// Variant A: for a capable model or a local agent, which can read web pages.
    public static let templateA = #"""
You make one keyboard-shortcut pack for Sanketa, a macOS app. Sanketa shows the keys of the app in front in a small panel. Your output is one TOML file.

## The app

- Name: {{app_name}}
- Version: {{app_version}}
- macOS bundle id: {{bundle_id}}
- Pack id: {{pack_id}}

## Keys that Sanketa already shows

Sanketa reads the menu bar of the app. It already shows these {{menu_count}} menu shortcuts:

```
{{menu_keys}}
```

Do not add a key that is on this list. Add only keys that the menus do not show: keys in the canvas or the editor, single-letter keys, mouse and key actions, and keys that only the docs give. You can change a menu label only if it is not clear. To do this, write the key exactly as the list does.

{{#existing_pack}}
The user already has this pack. Keep its entries. Add to it. Do not repeat its keys or tip titles.

```toml
{{existing_pack}}
```
{{/existing_pack}}

## Sources

Use the official documentation of the app. Start with these pages:

{{docs_urls}}

If there are no pages above, find the official keyboard-shortcut page of the app. Use the site of the developer, the official wiki or manual, or the release notes. Do not use third-party shortcut sites or posters as the only source of a key. If you can read the source code of the app, you can use it to check a key.

Rules for sources:

- Give each entry a `# src:` comment with the source tag. List each tag and its full URL at the top of the file.
- If a page gives 404, try a web archive copy. Write the archive URL in the source list.
- If two sources do not agree, use the newer source. Write a `# doubt:` comment that tells what is different.
- Do not make up a key. If you are not sure of a key, do not add it, or add it with a `# doubt:` comment.

## Mac keys

Many apps that also run on Windows and Linux use Ctrl. On macOS, some of these apps change Ctrl to ⌘, and some do not. Find which is true for this app:

- A native Mac app, or an app whose Mac menus show ⌘, uses ⌘.
- A GTK, Qt or Java app can keep the Control key. Look in the docs or the source for a Mac section.
- Write the rule that you used in a comment at the top of the file.

Also check for keys that macOS uses by default, such as ⌃F2 to ⌃F4, ⌃↑, ⌃←, ⌃→ and ⌘space. If the app uses one, keep the key. Add a tip that tells how to free it in System Settings.

## Pack format

{{schema}}

## What to write

Write one TOML file. Do not write other text before or after it. The file must have:

1. A comment block at the top: the source list, the Mac key rule, and each doubt.
2. `id = "{{pack_id}}"`, `name = "{{app_name}}"` and `apps = ["{{bundle_id}}"]`. Do not write `processes`, `match`, `prefix`, `title_scope` or `contexts`.
3. 15 to 60 `[[keys]]` entries. Put each key in a `group`. Use 4 to 12 groups. Name each group after a part of the app, such as "Editor: view" or "File Browser". Put the most useful keys first.
4. 5 to 15 `[[tips]]` entries. Each tip teaches one task that a new user does often. The `snippet` gives the real steps, such as `w, click a grey area, then right-click`. Use `→` between menu items and `, then` between steps. The `explain` tells what the result is, or when to use it.
5. A `# src:` comment after each `[[keys]]` and `[[tips]]` header, such as `[[keys]]   # src: KS`.

## Words

Write the `action`, `explain`, group names and comments in ASD-STE100 Simplified Technical English, at US grade 9:

- Use short sentences: 20 words or fewer for a step, 25 or fewer for a description.
- Write one instruction in each sentence. Use the imperative for steps: "Click", "Push", "Drag".
- Use the active voice.
- Use simple words: "use", not "utilise"; "start", not "initiate"; "show", not "display".
- Use one name for one thing. Use the names that the app uses, such as "File Browser" or "Queue".
- Do not use idioms. Use one verb in place of a phrasal verb when you can: "remove", not "take out".
- An `action` has 6 words or fewer. Do not end it with a period.
"""#

    /// Variant B: for the small on-device model, which gets the docs text from the user.
    public static let templateB = #"""
Make a Sanketa shortcut pack for the macOS app {{app_name}}. Output only TOML.

Start with exactly these 3 lines:
id = "{{pack_id}}"
name = "{{app_name}}"
apps = ["{{bundle_id}}"]

Then write 10 to 25 keys and 3 to 6 tips in this format:

[[keys]]
keys = "⌃S"
action = "Save the image"
group = "Editor"

[[tips]]
title = "Compare with the original"
snippet = "B"
explain = "Shows the photo before and after your edits."

Rules:
- Use only keys from the DOCS below. Do not make up keys.
- Do not use keys from the MENU list. Sanketa shows them already.
- Write keys in Mac symbols. Put modifiers in this order: ⌃ ⌥ ⇧ ⌘. Examples: ⌃S, ⌃⇧Z, ⌥F, F3, ↩, esc, tab, space, ↑.
- Write "Ctrl" as ⌃, "Alt" as ⌥, "Shift" as ⇧. Write "Cmd" as ⌘. {{ctrl_rule}}
- Write a plain letter as it is: "z". Write Shift and a letter as a capital: "B".
- Write two keys for one action as "[ / ]".
- action: 6 words or fewer. Simple English. No period.
- group: the part of the app, such as "Editor" or "File Browser". Use 3 to 8 groups.
- tip snippet: the real keys or steps. tip explain: one short sentence.
- Do not write any other fields. Do not write comments.

MENU (do not repeat):
{{menu_keys}}

DOCS:
{{docs_text}}
"""#

    /// The part of docs/packs.md that a model needs for a GUI-app pack (`{{schema}}`). Change it when docs/packs.md changes.
    public static let schema = #"""
A pack is one TOML file. Put the top-level fields before the first `[[keys]]` entry.

Top-level fields: `id` (string, required), `name` (string, required), `apps` (array of macOS bundle ids). Other top-level fields exist, but do not use them for this pack.

Each `[[keys]]` table has only these fields:
- `keys` (string, required): the key or keys, in the key style below.
- `action` (string, required): what the key does, in 6 words or fewer.
- `group` (string): the heading. Keys with the same group show together.

Each `[[tips]]` table has only these fields:
- `title` (string, required): a short heading. It must be unique in the pack.
- `snippet` (string, required): the keys or the steps to do.
- `explain` (string): one or two short sentences.
- `tags` (array of strings): more words for search.

Key style:
- Write keys in Mac symbols: ⌃ (control), ⌥ (option), ⇧ (shift), ⌘ (command).
- Put the modifiers in this order: ⌃ ⌥ ⇧ ⌘. Write `⇧⌘P`, not `⌘⇧P`. Write `⌃⇧Z`, not `⇧⌃Z`.
- A letter with a modifier is a capital: `⌃S`, not `⌃s`.
- A letter with no modifier is as you type it: `a` is a, `A` is shift-a.
- Return and Delete: `↩` `⌫`. Escape, Tab, forward delete: `esc` `tab` `del`. Do not write `Enter`, `Esc`, `⎋` or `⇥`.
- Arrows: `↑` `↓` `←` `→`. Function keys and paging: `F5` `pgup` `pgdn` `home` `end`. Space bar: `space`.
- A sequence has a space between the steps: `⌃X ⌃E`.
- Alternatives have ` / ` between them: `[ / ]`, `⌃P / ⌃N`.
- A range of keys uses an en dash: `1–5`, `⌥1–⌥9`.
- A mouse action is a modifier and a word, in a tip: `⌃ drag a curve point`.

The lint (`Sanketa --lint-pack`) gives an error for: a missing required field; a field that it does not know; a field with the wrong type; a key that is not in the key style; and two keys with the same `keys` text in one group. It gives a warning for an action of more than 6 words and two tips with the same title.

TOML: in a double-quoted string, write `\"` for a quote and `\\` for a backslash. A single-quoted string is literal. A comment starts with `#`.
"""#
}
