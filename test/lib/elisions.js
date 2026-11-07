/* Cherche les élisions écrites avec une ESPACE au lieu d'une apostrophe, dans les textes
   vus par l'utilisateur : « Règles d accès », « Aucun groupe pour l instant ».

   Pourquoi un contrôle et pas une relecture : le heredoc du panneau est quoté, l'apostrophe
   n'a donc jamais eu besoin d'être évitée — mais l'habitude prise dans les COMMENTAIRES,
   où elle gênait, a débordé sur les chaînes affichées. Seize textes du panneau et deux
   messages du CLI l'avaient perdue, dont un titre d'onglet et deux titres de fenêtre.
   Chacun se lit à l'écran, et aucun test ne les regardait.

   Usage : node elisions.js <chemin/vers/wg-pi.sh>
   Sort en 1 et liste les fautes, 0 si tout est propre. */
"use strict";
const fs = require("fs");

const F = process.argv[2];
if (!F) { console.error("usage : elisions.js <chemin/vers/wg-pi.sh>"); process.exit(2); }
const lignes = fs.readFileSync(F, "utf8").split("\n");

/* Les élisions du français. « t » couvre « c est t il » ? Non : le t euphonique s'écrit
   avec des traits d'union, donc « t a » est forcément une variable de code ; on l'exclut
   pour ne pas crier sur « read -r type a b c d ». */
const ELISION = /(^|[^A-Za-zÀ-ÿ'’-])(l|d|n|s|c|j|m|qu|jusqu|lorsqu|puisqu|quelqu|aujourd) ((?:h?[aeiouyàâäéèêëîïôöûü])[A-Za-zÀ-ÿ]*)/;

/* « for d in WG_PATHS », « if s and … » : du Python ou du JavaScript qui prend la forme
   d'une élision. Le français n'écrit jamais « d in ». Sans ce filtre, une ligne qui mêle
   les deux sortes de guillemets fait apparier les mauvais, et le fragment de code qui
   dépasse remonte comme une faute de frappe. */
const MOTS_DE_CODE = ["in", "if", "is", "and", "or", "not", "else", "elif", "import",
                      "as", "of", "end", "int", "str", "args", "else"];

/* Du code, pas une phrase : une règle iptables, un programme awk, un motif, un gabarit.
   Les messages de wg-pi n'emploient aucun de ces caractères. */
function estDuCode(s) {
  if (/[${}<>=*\\|]/.test(s)) { return true; }
  if (/^\s*-/.test(s)) { return true; }
  if (!/ /.test(s)) { return true; }
  return false;
}

/* Le texte d'une ligne de HTML, balises et champs de remplacement retirés. */
function texteHtml(l) {
  if (l.indexOf("<") < 0) { return ""; }
  return l.replace(/\{[^{}]*\}/g, " ").replace(/<[^>]*>/g, " ");
}

/* Les pages HTML du panneau sont des f-strings : leur texte n'est pas un littéral que la
   recherche de chaînes trouverait. On repère donc leurs lignes, et là seulement on lit le
   texte hors balises. Ailleurs, une expression Python contenant du HTML — « join(f'<path
   d="{d}"/>' for d in …) » — laisserait « for d in » après retrait des balises, et crierait
   sur du code. */
const DANS_PAGE = lignes.map(function () { return false; });
lignes.forEach(function (l, i) {
  if (!/f"""/.test(l)) { return; }
  for (let j = i; j < lignes.length; j++) {
    DANS_PAGE[j] = true;
    if (j > i && /^\s*"""/.test(lignes[j])) { return; }
    if (j > i && /"""/.test(lignes[j])) { return; }
  }
});

let dansBloc = false;
const fautes = [];
for (let i = 0; i < lignes.length; i++) {
  let l = lignes[i];

  /* Commentaires /* … *​/ du JavaScript et du CSS, éventuellement sur plusieurs lignes. */
  if (dansBloc) {
    const f = l.indexOf("*/");
    if (f < 0) { continue; }
    l = l.slice(f + 2);
    dansBloc = false;
  }
  for (;;) {
    const d = l.indexOf("/*");
    if (d < 0) { break; }
    const f = l.indexOf("*/", d + 2);
    if (f < 0) { l = l.slice(0, d); dansBloc = true; break; }
    l = l.slice(0, d) + " " + l.slice(f + 2);
  }
  /* Commentaire bash ou Python en début de ligne, et docstring. */
  if (/^\s*#/.test(l)) { continue; }
  if (/^\s*"""/.test(l)) { continue; }

  const morceaux = [];
  const re = /"([^"\n]{4,})"|'([^'\n]{4,})'/g;
  let m;
  while ((m = re.exec(l)) !== null) {
    morceaux.push(m[1] !== undefined ? m[1] : m[2]);
  }
  if (DANS_PAGE[i]) {
    const html = texteHtml(l);
    if (html.trim()) { morceaux.push(html); }
  }

  morceaux.forEach(function (s) {
    if (estDuCode(s)) { return; }
    const e = ELISION.exec(s);
    if (!e) { return; }
    if (MOTS_DE_CODE.indexOf(e[3].toLowerCase()) >= 0) { return; }
    fautes.push({ ligne: i + 1, mot: e[2] + " " + e[3], texte: s.trim().slice(0, 100) });
  });
}

if (!fautes.length) {
  console.log("aucune élision sans apostrophe");
  process.exit(0);
}
fautes.forEach(function (x) {
  console.log(F + ":" + x.ligne + "  « " + x.mot + " » : " + x.texte);
});
process.exit(1);
