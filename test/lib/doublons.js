/* Détecte deux « function X » déclarées au MÊME niveau d'indentation dans un même
   fichier, c'est-à-dire presque toujours dans la même portée.

   En JavaScript, la seconde déclaration écrase silencieusement la première : tous les
   appels écrits pour la première partent alors avec la mauvaise signature, sans erreur,
   sans avertissement. C'est arrivé à « svgEl » : la version posée avec la carte,
   svgEl(tag, classe), a écrasé svgEl(tag, attributs), et l'appel du sparkline s'est mis
   à poser class="[object Object]" tout en perdant son viewBox. Le panneau continuait de
   fonctionner, mais chaque ligne d'appareil était décalée d'une colonne et le sparkline
   s'affichait en noir opaque, haut de 150 px.

   « node --check » ne voit rien là-dedans : le fichier est parfaitement valide.

   Usage : node doublons.js fichier.js [fichier.js...] */
"use strict";
const fs = require("fs");

const MOT = "function ";
let defauts = 0;

process.argv.slice(2).forEach(function (chemin) {
  const nomFichier = chemin.split("/").pop();
  const vues = Object.create(null);
  let lignes;
  try {
    lignes = fs.readFileSync(chemin, "utf8").split("\n");
  } catch (e) {
    return;
  }
  lignes.forEach(function (ligne, i) {
    const debut = ligne.indexOf(MOT);
    if (debut < 0) { return; }
    /* Seulement une declaration en tete de ligne : « var f = function (...) » et
       « x.y = function nom() » ne sont pas des declarations hissees. */
    if (ligne.slice(0, debut).trim() !== "") { return; }
    const reste = ligne.slice(debut + MOT.length);
    const paren = reste.indexOf("(");
    if (paren < 0) { return; }
    const nom = reste.slice(0, paren).trim();
    if (!nom || nom.indexOf(" ") >= 0) { return; }
    const cle = debut + ":" + nom;
    if (vues[cle]) {
      defauts += 1;
      console.log(nomFichier + " : « function " + nom + " » déclarée deux fois au même "
        + "niveau (lignes " + vues[cle] + " et " + (i + 1) + ") ; la seconde écrase la première");
    } else {
      vues[cle] = i + 1;
    }
  });
});

process.exit(defauts ? 1 : 0);
