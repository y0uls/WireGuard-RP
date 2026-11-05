/* Exécute le JavaScript du panneau sous node, avec un DOM simulé, et vérifie le rendu de
   la vue d'accès. C'est l'étape que « node --check » ne remplace pas : ici le code TOURNE,
   donc une variable non déclarée ou un appel sur undefined lèvent. */
"use strict";
const path = require("path");
const stub = require(path.join(__dirname, "dom-stub.js"));

const APP = process.argv[2];
if (!APP) { console.error("usage : ui-run.js <chemin/vers/app.js>"); process.exit(2); }

const env = stub.install([]);
let app;
try {
  app = require(path.resolve(APP));
} catch (e) {
  console.log("  KO   le chargement du panneau lève : " + e.message);
  process.exit(1);
}

let pass = 0, fail = 0;
function ok(m) { console.log("  OK   " + m); pass++; }
function ko(m, got, want) {
  console.log("  KO   " + m);
  if (arguments.length > 1) {
    console.log("       obtenu  : [" + got + "]");
    console.log("       attendu : [" + want + "]");
  }
  fail++;
}
function eq(m, got, want) { if (got === want) { ok(m); } else { ko(m, got, want); } }
function contient(m, texte, motif) {
  if (String(texte).indexOf(motif) >= 0) { ok(m); } else { ko(m, texte, "contient " + motif); }
}

if (typeof app.renderAcces !== "function") {
  ko("la couture de test n'expose pas renderAcces");
  process.exit(1);
}
ok("le panneau se charge et s'exécute sans lever");

function G(id, libelle, appareils, flux, auto) {
  return {id: id, libelle: libelle, appareils: appareils, flux: flux || [], auto: !!auto};
}
function F(id, dest, label, proto, ports, sens) {
  return {id: id, dest: dest, label: label, proto: proto || "any",
          ports: ports || "", sens: sens || "aller", titre: ""};
}
function render(acces) {
  app.setState({acces: acces, peers: [], server: {}, time: 1});
  app.renderAcces();
  return {
    etat: env.doc.getElementById("acc-state"),
    warn: env.doc.getElementById("acc-warn"),
    matrix: env.doc.getElementById("acc-matrix"),
    listen: env.doc.getElementById("acc-listen")
  };
}
function vide() {
  return {mode: "ouvert", noyau: "inactif", groupes: [], ressources: [], ecoute: []};
}

/* --- bandeau d'état : il doit refléter le NOYAU, pas le fichier ------------- */
let r = render(vide());
eq("mode ouvert : aucun cloisonnement", r.etat.textContent, "Aucun cloisonnement");
eq("mode ouvert : pas d'avertissement", r.warn.hidden, true);

r = render({mode: "filtre", noyau: "actif", groupes: [], ressources: [], ecoute: []});
eq("filtrage actif", r.etat.textContent, "Filtrage actif");
eq("classe de la pastille", r.etat.className, "pill ok");
eq("filtrage actif : pas d'avertissement", r.warn.hidden, true);

/* Le cas qui compte : le fichier demande le filtrage, mais le noyau ne l'applique pas —
   après un « ufw reload » ou un redémarrage de Docker. Le panneau doit le dire, et
   surtout ne jamais annoncer un cloisonnement inexistant. */
r = render({mode: "filtre", noyau: "incoherent", groupes: [], ressources: [], ecoute: []});
eq("règles non appliquées", r.etat.textContent, "Règles non appliquées");
eq("pastille en rouge", r.etat.className, "pill bad");
eq("avertissement visible", r.warn.hidden, false);
contient("l'avertissement est explicite", r.warn.textContent, "PAS appliquées");

r = render({mode: "filtre", noyau: "inconnu", groupes: [], ressources: [], ecoute: []});
eq("état non vérifiable : pastille neutre", r.etat.textContent, "Filtrage demandé");
eq("état non vérifiable : averti quand même", r.warn.hidden, false);

/* --- matrice --------------------------------------------------------------- */
r = render(vide());
contient("aucune règle : message au lieu d'un tableau vide", stub.textOf(r.matrix), "Aucune règle");

const acces = {
  mode: "filtre", noyau: "actif", ecoute: [22, 443],
  ressources: [{id: "nas", libelle: "NAS", cible: "192.168.1.20"}],
  groupes: [
    G("confiance", "Appareils de confiance", ["telephone", "pc"], [
      F("p1", "res:nas", "NAS (192.168.1.20)", "tcp", "445,5000-5001"),
      F("p2", "internet", "Internet")
    ]),
    G("invites", "Invités", ["tablette"], [F("p3", "internet", "Internet")]),
    G("tous", "Tous les appareils", ["telephone", "pc", "tablette"], [], true)
  ]
};
r = render(acces);
const tables = stub.findAll(r.matrix, "TABLE");
eq("un seul tableau", tables.length, 1);
const entetes = stub.findAll(stub.findAll(tables[0], "THEAD")[0], "TH");
eq("coin + deux destinations", entetes.length, 3);
eq("première colonne : le coin", entetes[0].className, "corner");
/* Internet avant la ressource : le trafic de masse en premier, comme dans les règles. */
eq("Internet avant la ressource", entetes[1].textContent, "Internet");
eq("la ressource ensuite", entetes[2].textContent, "NAS (192.168.1.20)");

const lignes = stub.findAll(stub.findAll(tables[0], "TBODY")[0], "TR");
eq("une ligne par groupe", lignes.length, 3);
const cellules = stub.findAll(lignes[0], "TD");
eq("deux cellules sur la première ligne", cellules.length, 2);
eq("accès accordé vers Internet", cellules[0].className, "yes");
eq("accès accordé vers la ressource", cellules[1].className, "yes");
contient("les ports sont affichés tels que saisis", stub.textOf(cellules[1]), "445,5000-5001");

/* Une cellule sans règle doit être HACHURÉE et non vide : « aucune règle » ne doit pas se
   confondre avec « pas encore chargé ». */
const sansRegle = stub.findAll(lignes[1], "TD")[1];
eq("absence de règle marquée", sansRegle.className, "no");
eq("absence de règle annoncée aux lecteurs d'écran", sansRegle.getAttribute("aria-label"), "aucune règle");

contient("le groupe automatique est signalé", stub.textOf(stub.findAll(lignes[2], "TH")[0]), "automatique");
contient("le nombre d'appareils est affiché", stub.textOf(lignes[0]), "2 appareils");

/* --- ports en écoute ------------------------------------------------------- */
eq("note des ports visible", r.listen.hidden, false);
contient("les ports en écoute sont listés", r.listen.textContent, "22, 443");
r = render(vide());
eq("note masquée sans port", r.listen.hidden, true);

/* --- formatage ------------------------------------------------------------- */
eq("protocole any", app.fluxTexte(F("x", "internet", "Internet")), "tout");
eq("protocole et ports", app.fluxTexte(F("x", "internet", "I", "tcp", "443")), "tcp 443");
eq("sens deux signalé", app.fluxTexte(F("x", "grp:a", "A", "any", "", "deux")), "tout ⇄");
eq("rang internet", app.destRang("internet"), 1);
eq("rang ressource", app.destRang("res:nas"), 4);
eq("rang groupe", app.destRang("grp:a"), 5);

/* --- robustesse : un état incomplet ne doit pas faire planter le panneau ---- */
try {
  app.setState({acces: {}, peers: [], server: {}, time: 1});
  app.renderAcces();
  ok("une vue d'accès vide ne lève pas");
} catch (e) {
  ko("une vue d'accès vide lève : " + e.message);
}
try {
  app.setState({peers: [], server: {}, time: 1});
  app.renderAcces();
  ok("une réponse sans vue d'accès ne lève pas");
} catch (e) {
  ko("une réponse sans vue d'accès lève : " + e.message);
}


/* --- carte ----------------------------------------------------------------- */
function P(name, groupes, down, up, enabled, connected) {
  return {name: name, ip: "10.8.0.2", groupes: groupes, down: down || 0, up: up || 0,
          enabled: enabled !== false, connected: !!connected, rx: 0, tx: 0, mode: "split"};
}
function renderCarte(acces, peers) {
  app.mapReset();
  app.setState({acces: acces, peers: peers, server: {}, time: 1});
  app.renderMap();
  return env.doc.getElementById("map-box");
}

const accesCarte = {
  mode: "filtre", noyau: "actif", ecoute: [],
  ressources: [{id: "nas", libelle: "NAS", cible: "192.168.1.20"}],
  groupes: [
    G("confiance", "Confiance", ["telephone"], [
      F("p1", "internet", "Internet"),
      F("p2", "res:nas", "NAS (192.168.1.20)", "tcp", "445")
    ]),
    G("invites", "Invités", ["tablette"], [F("p3", "internet", "Internet", "any", "", "deux")])
  ]
};
const pairs = [
  P("telephone", ["confiance", "tous"], 500000, 100000, true, true),
  P("tablette", ["invites", "tous"], 0, 0, true, false),
  P("vieux-pc", ["tous"], 0, 0, false, false)
];

let box = renderCarte(accesCarte, pairs);
let svgs = stub.findAll(box, "SVG");
eq("un SVG est produit", svgs.length, 1);
const liens = stub.findAll(svgs[0], "PATH");

function parClasse(motif) {
  return liens.filter(function (l) { return (l.getAttribute("class") || "").indexOf(motif) >= 0; });
}
eq("un lien par appareil vers le Pi", parClasse("axis").length, 3);

/* Un appareil qui ne transmet rien ne doit PAS etre anime : un point qui circule sur une
   liaison inactive serait un mensonge visuel. */
const animes = parClasse("live");
eq("seul l appareil qui transmet est animé", animes.length, 1);
eq("l appareil animé est le bon", animes[0].getAttribute("data-dev"), "telephone");
eq("palier de vitesse intermédiaire", animes[0].getAttribute("class").indexOf("s2") >= 0, true);

const coupe = liens.filter(function (l) { return l.getAttribute("data-dev") === "vieux-pc"; })[0];
contient("un appareil désactivé est marqué", coupe.getAttribute("class"), "off");
eq("un appareil désactivé n est jamais animé", coupe.getAttribute("class").indexOf("live"), -1);

/* L intensite doit passer par stroke-opacity : un « opacity » en style inline
   l emporterait sur la feuille de style et bloquerait l estompage du mode focus. */
eq("intensité portée par stroke-opacity", typeof animes[0].style.strokeOpacity, "string");
eq("aucune opacity inline", animes[0].style.opacity === undefined || animes[0].style.opacity === "", true);

const pol = parClasse("pol");
eq("trois arêtes de politique", pol.length, 3);
contient("couleur de groupe sur l arête", pol[0].getAttribute("class"), "g1");
eq("tous les ports : trait épais", parClasse("wide").length, 2);
eq("sens unique : trait pointillé", parClasse("oneway").length, 2);
/* Le trafic ne doit JAMAIS animer une arete de politique : rien ne permet d attribuer
   un debit a une regle precise. */
eq("aucune arête de politique animée", pol.filter(function (l) {
  return (l.getAttribute("class") || "").indexOf("live") >= 0;
}).length, 0);

eq("paliers de débit", [app.mapTier(1000), app.mapTier(500000), app.mapTier(5000000)].join(","), "1,2,3");
eq("débit en Mo/s", app.humanRate(2500000), "2.5 Mo/s");
eq("débit en ko/s", app.humanRate(45000), "45 ko/s");
eq("débit en o/s", app.humanRate(300), "300 o/s");

/* --- mode focus ------------------------------------------------------------ */
const noeudDev = stub.findAll(svgs[0], "G").filter(function (g) {
  return g.getAttribute("data-dev") === "telephone";
})[0];
app.mapClick(noeudDev);
eq("le focus est mémorisé", app.mapFocusKey(), "dev:telephone");
box = env.doc.getElementById("map-box");
svgs = stub.findAll(box, "SVG");
contient("le SVG passe en mode focus", svgs[0].getAttribute("class"), "focus");
const selectionnes = stub.findAll(svgs[0], "PATH").filter(function (l) {
  return (l.getAttribute("class") || "").indexOf("sel") >= 0;
});
eq("seul le lien de l appareil est sélectionné", selectionnes.length, 1);
/* « sel » et non « on » : « on » marque deja les appareils connectes. */
eq("le marqueur de focus n est pas « on »", selectionnes[0].getAttribute("class").indexOf(" on") , -1);
app.mapClick(noeudDev);
eq("un second clic rétablit tout", app.mapFocusKey(), null);

/* --- cas limites ----------------------------------------------------------- */
box = renderCarte(accesCarte, []);
eq("aucun appareil : aucune carte", stub.findAll(box, "SVG").length, 0);
try {
  renderCarte({}, pairs);
  ok("une carte sans règles ne lève pas");
} catch (e) {
  ko("une carte sans règles lève : " + e.message);
}
eq("la légende est posée", env.doc.getElementById("map-legend").hidden, false);


/* --- fiche d'accès d'un appareil ------------------------------------------- */
const accesFiche = {
  mode: "filtre", noyau: "actif", ecoute: [],
  ressources: [{id: "nas", libelle: "NAS", cible: "192.168.1.20"}],
  groupes: [
    G("famille", "Ma famille", ["telephone", "pc"], [
      F("p1", "internet", "Internet"),
      F("p2", "res:nas", "NAS (192.168.1.20)", "tcp", "445")
    ]),
    G("invites", "Invités", ["tablette"], [
      F("p3", "internet", "Internet"),
      F("p4", "grp:famille", "Le groupe « Ma famille »", "any", "", "deux")
    ]),
    G("tous", "Tous les appareils", ["telephone", "pc", "tablette"], [F("p5", "pi", "Le Raspberry Pi lui-même")], true)
  ]
};
const pairsFiche = [
  P("telephone", ["famille", "tous"], 0, 0, true, true),
  P("solitaire", ["tous"], 0, 0, true, false)
];
app.setState({acces: accesFiche, peers: pairsFiche, server: {}, time: 1});

eq("groupes nommés, « tous » exclu", app.groupesNommes(pairsFiche[0]).join(","), "famille");
eq("un appareil sans groupe nommé", app.groupesNommes(pairsFiche[1]).length, 0);

/* Les flux sortants cumulent les groupes de l'appareil, « tous » compris. */
const sortants = app.fluxSortants("telephone");
eq("trois flux sortants pour telephone", sortants.length, 3);
eq("dont la règle du groupe automatique", sortants.filter(function (x) {
  return x.flux.id === "p5";
}).length, 1);
eq("un appareil sans groupe nommé hérite de « tous »", app.fluxSortants("solitaire").length, 1);
eq("un appareil inconnu n'a aucun flux", app.fluxSortants("fantome").length, 0);

/* Les flux entrants : les règles dont la destination est un groupe dont il fait partie. */
const entrants = app.fluxEntrants("telephone");
eq("un flux entrant vers telephone", entrants.length, 1);
eq("il vient du bon groupe", entrants[0].groupe.id, "invites");
eq("et il est bidirectionnel", entrants[0].flux.sens, "deux");
eq("personne ne peut joindre solitaire", app.fluxEntrants("solitaire").length, 0);

/* La fiche s'ouvre et se remplit sans lever. */
try {
  app.openAcces("telephone");
  const corps = env.doc.getElementById("dlg-body");
  const txt = stub.textOf(corps);
  ok("la fiche s'ouvre sans lever");
  contient("le titre nomme l'appareil", txt, "telephone");
  contient("les groupes sont listés", txt, "Ma famille");
  contient("ce qu'il peut joindre", txt, "Peut joindre");
  contient("ce qui peut le joindre", txt, "Peut être joint par");
  contient("les ports sont affichés", txt, "tcp 445");
  /* La limite doit être dite dans la fiche, pas découverte à ses frais. */
  contient("la limite des services du Pi est rappelée", txt, "services qui tournent sur le Pi");
} catch (e) {
  ko("la fiche lève : " + e.message);
}

/* Hors filtrage, la fiche doit dire que rien ne s'applique : sans cela, la liste se
   lirait comme une restriction effective. */
try {
  app.setState({acces: Object.assign({}, accesFiche, {mode: "ouvert"}), peers: pairsFiche, server: {}, time: 1});
  app.openAcces("telephone");
  contient("hors filtrage, la fiche le dit", stub.textOf(env.doc.getElementById("dlg-body")),
           "Aucun cloisonnement");
} catch (e) {
  ko("la fiche lève hors filtrage : " + e.message);
}
try {
  app.setState({acces: Object.assign({}, accesFiche, {noyau: "incoherent"}), peers: pairsFiche, server: {}, time: 1});
  app.openAcces("telephone");
  contient("règles non appliquées : la fiche le dit", stub.textOf(env.doc.getElementById("dlg-body")),
           "ne sont PAS appliquées");
} catch (e) {
  ko("la fiche lève sur un état incohérent : " + e.message);
}
try {
  app.setState({acces: {}, peers: pairsFiche, server: {}, time: 1});
  app.openAcces("telephone");
  ok("une fiche sans vue d'accès ne lève pas");
} catch (e) {
  ko("une fiche sans vue d'accès lève : " + e.message);
}

console.log("");
console.log("  " + pass + " réussi(s), " + fail + " échoué(s)");
process.exit(fail === 0 ? 0 : 1);
