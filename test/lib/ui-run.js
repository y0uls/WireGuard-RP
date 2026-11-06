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
/* Ce qui compte est l ORDRE des colonnes, pas la valeur des rangs : fixer les nombres
   faisait echouer trois tests au seul ajout d une destination, sans qu aucun
   comportement visible ait change. */
eq("les colonnes vont du plus large au plus precis",
   ["grp:a", "res:nas", "pi", "maison", "internet", "tout"]
     .sort(function (x, y) { return app.destRang(x) - app.destRang(y); }).join(" "),
   "tout internet maison pi res:nas grp:a");
eq("une destination inconnue ne casse pas le tri",
   typeof app.destRang("quelque-chose"), "number");

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
/* Le focus doit suivre le CHEMIN COMPLET. Les liens de gauche portent « data-dev »,
   ceux de droite « data-grp » et « data-dest » : une mise en evidence qui ne filtre que
   sur l attribut du type clique s arrete au Pi, et laisse croire que la question
   « et ensuite, qu est-ce qu il atteint ? » n a pas de reponse. */
function noeudCarte(svg, attr, val) {
  return stub.findAll(svg, "G").filter(function (g) { return g.getAttribute(attr) === val; })[0];
}
function vueFocus() {
  const s = stub.findAll(env.doc.getElementById("map-box"), "SVG")[0];
  function marques(liste) {
    return liste.filter(function (e) { return (e.getAttribute("class") || "").indexOf("sel") >= 0; });
  }
  return {svg: s, liens: marques(stub.findAll(s, "PATH")), noeuds: marques(stub.findAll(s, "G"))};
}

app.mapClick(noeudCarte(svgs[0], "data-dev", "telephone"));
eq("le focus est mémorisé", app.mapFocusKey(), "dev:telephone");
let vf = vueFocus();
contient("le SVG passe en mode focus", vf.svg.getAttribute("class"), "focus");
/* « telephone » est dans « confiance », qui mene a Internet et au NAS : son lien vers le
   Pi, plus ces deux regles. */
eq("le chemin ne s arrête pas au Pi", vf.liens.length, 3);
eq("les destinations joignables sont allumées",
   vf.noeuds.filter(function (g) { return g.getAttribute("data-dest"); })
     .map(function (g) { return g.getAttribute("data-dest"); }).sort().join(","),
   "internet,res:nas");
/* Un lien de politique n est retenu que si SES DEUX bouts le sont : sinon, selectionner
   un appareil allumerait la regle d un AUTRE groupe vers la meme destination, et
   donnerait a lire un droit qu il n a pas. */
eq("la règle de l autre groupe reste éteinte",
   vf.liens.filter(function (l) { return l.getAttribute("data-grp") === "invites"; }).length, 0);
eq("l appareil d un autre groupe reste éteint",
   vf.liens.filter(function (l) { return l.getAttribute("data-dev") === "tablette"; }).length, 0);
/* « sel » et non « on » : « on » marque deja les appareils connectes. */
eq("le marqueur de focus n est pas « on »", vf.liens[0].getAttribute("class").indexOf(" on"), -1);
app.mapClick(noeudCarte(vf.svg, "data-dev", "telephone"));
eq("un second clic rétablit tout", app.mapFocusKey(), null);

/* Symétrie : une destination montre QUI peut l atteindre. */
svgs = stub.findAll(env.doc.getElementById("map-box"), "SVG");
app.mapClick(noeudCarte(svgs[0], "data-dest", "internet"));
eq("le focus retient la destination", app.mapFocusKey(), "dest:internet");
vf = vueFocus();
/* Deux groupes menent a Internet : les deux appareils, leurs liens vers le Pi, et les
   deux regles. */
eq("les deux appareils et leurs règles", vf.liens.length, 4);
eq("la règle vers le NAS reste éteinte",
   vf.liens.filter(function (l) { return l.getAttribute("data-dest") === "res:nas"; }).length, 0);
app.mapClick(noeudCarte(vf.svg, "data-dest", "internet"));
eq("un second clic rétablit tout (destination)", app.mapFocusKey(), null);

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

/* La légende ne doit décrire que ce qui est à l'écran : sans règle, pas d'arête de
   politique, donc pas un mot sur leur épaisseur ni leurs pointillés. */
renderCarte({mode: "ouvert", noyau: "inactif", groupes: [], ressources: [], ecoute: []}, pairs);
const legSansRegle = env.doc.getElementById("map-legend").textContent;
contient("sans règle, la légende annonce la colonne vide", legSansRegle, "se remplira");
eq("sans règle, elle ne parle pas de trait épais", legSansRegle.indexOf("trait épais"), -1);
eq("sans règle, elle ne parle pas de pointillé", legSansRegle.indexOf("pointillé"), -1);
contient("elle parle quand même du débit", legSansRegle, "débit réel");

renderCarte(accesCarte, pairs);
const legAvecRegle = env.doc.getElementById("map-legend").textContent;
contient("avec des règles, elle décrit le trait épais", legAvecRegle, "trait épais");
contient("et le mode focus", legAvecRegle, "Cliquez");


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

/* ---- Groupes, ressources, règles et bascule ---- */
const accesGestion = {
  mode: "filtre", noyau: "actif", confirme: false,
  groupes: [
    G("famille", "Ma famille", ["telephone", "tablette"],
      [F("r1", "internet", "Internet"), F("r2", "res:nas", "Le NAS", "tcp", "445,5000-5001")]),
    G("vide", "Groupe sans personne", []),
    G("tous", "Tous les appareils", ["telephone"], [], true)
  ],
  ressources: [{id: "nas", libelle: "Le NAS", cible: "192.168.1.20"}],
  ecoute: [22, 443]
};
const pairsGestion = [{name: "telephone"}, {name: "tablette"}, {name: "pc-bureau"}];

function rendreGestion(acces, pairs) {
  app.setState({acces: acces, peers: pairs || pairsGestion, server: {}, time: 1});
  app.renderGroupes();
  app.renderRegles();
  app.renderConfirmation();
  app.majBascule();
  return {
    groupes: env.doc.getElementById("grp-list"),
    ressources: env.doc.getElementById("res-list"),
    regles: env.doc.getElementById("acc-rules"),
    bandeau: env.doc.getElementById("acc-confirm"),
    bascule: env.doc.getElementById("acc-switch"),
    cGrp: env.doc.getElementById("c-grp"),
    cAcc: env.doc.getElementById("c-acc")
  };
}

let v = rendreGestion(accesGestion);
contient("le groupe est affiché avec son libellé", stub.textOf(v.groupes), "Ma famille");
contient("ses appareils apparaissent", stub.textOf(v.groupes), "telephone");
contient("un groupe vide le dit", stub.textOf(v.groupes), "aucun appareil");
/* « tous » est automatique : on ne le propose ni à la suppression ni à l'ajout de membres. */
eq("le groupe automatique n est pas listé", stub.textOf(v.groupes).indexOf("Tous les appareils"), -1);
eq("compteur des groupes nommés", v.cGrp.textContent, "2");
eq("compteur des règles", v.cAcc.textContent, "2");
contient("la ressource montre son adresse", stub.textOf(v.ressources), "192.168.1.20");

contient("la règle nomme sa destination", stub.textOf(v.regles), "Le NAS");
contient("les ports sont lisibles", stub.textOf(v.regles), "TCP 445,5000-5001");
contient("une règle sans port dit tous les ports", stub.textOf(v.regles), "tous les ports");
eq("une ligne par règle", stub.findAll(v.regles, "DIV").filter(function (d) {
  return d.className === "regle";
}).length, 2);

/* Le bandeau de confirmation se déduit de l'état du serveur, jamais d'une variable
   locale : sinon il disparaîtrait au premier rechargement de page, alors que le
   retour arrière automatique, lui, serait toujours armé. */
eq("filtrage non confirmé : le bandeau s affiche", v.bandeau.hidden, false);
contient("et il explique ce qui va se passer", stub.textOf(v.bandeau), "rétablira");
eq("filtrage actif : la bascule propose de couper", v.bascule.textContent, "Couper le filtrage");

v = rendreGestion(Object.assign({}, accesGestion, {confirme: true}));
eq("filtrage confirmé : pas de bandeau", v.bandeau.hidden, true);

v = rendreGestion(Object.assign({}, accesGestion, {mode: "ouvert"}));
eq("sans filtrage : pas de bandeau", v.bandeau.hidden, true);
eq("sans filtrage : la bascule propose d activer", v.bascule.textContent, "Activer le filtrage");

v = rendreGestion({});
contient("aucun groupe : le panneau le dit", stub.textOf(v.groupes), "Aucun groupe");
contient("aucune ressource : le panneau le dit", stub.textOf(v.ressources), "Aucune ressource");
contient("aucune règle : le panneau le dit", stub.textOf(v.regles), "Aucune règle");
eq("compteurs vides plutôt que zéro", v.cGrp.textContent + "/" + v.cAcc.textContent, "/");

/* --- ce que la relecture a corrigé ----------------------------------------- */
const source = require("fs").readFileSync(APP, "utf8");

/* /api/filtrage EXIGE une action : un corps vide lui fait répondre 400 « Action
   inconnue. ». C'est ainsi que « Couper le filtrage » est resté mort — le seul moyen,
   depuis le navigateur, de défaire un cloisonnement qui vous enferme. */
let sansAction = 0, pos = -1;
while ((pos = source.indexOf("/api/filtrage", pos + 1)) >= 0) {
  if (source.slice(pos, pos + 180).indexOf("action") < 0) { sansAction += 1; }
}
eq("chaque appel à /api/filtrage porte une action", sansAction, 0);

v = rendreGestion(accesGestion);
const pastilles = stub.findAll(v.groupes, "SPAN").filter(function (s) {
  return (s.className || "").indexOf("chip") >= 0;
});
/* « data-admin » masque l élément pour un compte de consultation. Posé sur la pastille
   entière, il masquait le NOM de l appareil : les groupes apparaissaient vides, ce qui
   est un mensonge et non une restriction. Il va sur le bouton de retrait. */
eq("la pastille d appartenance reste visible en lecture seule",
   pastilles.filter(function (s) { return s.getAttribute("data-admin") !== null; }).length, 0);
eq("mais son bouton de retrait est réservé à l administrateur",
   stub.findAll(v.groupes, "BUTTON").filter(function (b) {
     return b.textContent === "×" && b.getAttribute("data-admin") !== null;
   }).length > 0, true);

/* Un rendu qui reconstruit son conteneur alors que rien n a changé vole le focus et
   avale les clics : le relevé tourne toutes les deux secondes. */
const avantRendu = v.groupes.children[0];
app.renderGroupes();
eq("un rendu identique ne reconstruit rien", v.groupes.children[0] === avantRendu, true);
const avantRegles = v.regles.children[0];
app.renderRegles();
eq("idem pour les règles", v.regles.children[0] === avantRegles, true);
app.setState({acces: Object.assign({}, accesGestion, {
  groupes: accesGestion.groupes.concat([G("neuf", "Tout neuf", [])])
}), peers: pairsGestion, server: {}, time: 2});
app.renderGroupes();
contient("mais un changement réel est bien redessiné", stub.textOf(v.groupes), "Tout neuf");

/* Un objet littéral hérite de son prototype : « constructor » et « toString » y valent
   une fonction, donc vrai. Un appareil portant ce nom n était jamais proposé. */
app.setState({
  acces: {groupes: [G("g", "Groupe", ["telephone"])], ressources: []},
  peers: [{name: "telephone"}, {name: "constructor"}, {name: "toString"}],
  server: {}, time: 3
});
app.ouvrirAjoutMembre({id: "g", libelle: "Groupe", appareils: ["telephone"]});
const proposes = stub.findAll(env.doc.getElementById("dlg-body"), "OPTION")
  .map(function (o) { return o.value; }).sort().join(",");
eq("un appareil au nom hérité du prototype est proposé", proposes, "constructor,toString");

/* --- le formulaire de regle ------------------------------------------------- */
app.setState({
  acces: {groupes: [G("admin", "Administration", ["telephone"])],
          ressources: [{id: "nas", libelle: "Le NAS", cible: "192.168.1.20"}]},
  peers: [{name: "telephone"}], server: {}, time: 4
});
app.ouvrirNouvelleRegle();
const corps = env.doc.getElementById("dlg-body");
function selParId(id) {
  return stub.findAll(corps, "SELECT").filter(function (s) { return s.id === id; })[0];
}
const dst = selParId("reg-dst");
/* Donner tous les droits a un groupe demandait quatre regles, a completer a chaque
   nouveau groupe. « Tout le trafic » les remplace, et reprend le mot employe a la
   creation d un appareil. */
eq("« Tout le trafic » est proposé en premier", dst.children[0].value, "tout");
eq("et porte le même libellé qu à la création d un appareil",
   dst.children[0].textContent, "Tout le trafic");

/* Un champ inopérant SANS explication adjacente se lit comme une panne : c est
   exactement ce qui a ete signale a l usage. */
const sens = selParId("reg-sens");
eq("le sens est inopérant hors destination « Groupe »", sens.disabled, true);
contient("et il dit pourquoi, juste en dessous de lui",
         stub.textOf(sens.parentNode.children[2]), "Groupe");
const ports = stub.findAll(corps, "INPUT").filter(function (i) { return i.id === "reg-ports"; })[0];
eq("les ports sont inopérants sans TCP ni UDP", ports.disabled, true);
contient("et le disent aussi", stub.textOf(ports.parentNode.children[2]), "TCP");

/* --- modifier plutot que ressaisir ----------------------------------------- */
/* Ajouter un seul port a une regle obligeait a la supprimer puis a retaper toute la
   liste de memoire. Le meme formulaire sert donc aux deux, pre-rempli. */
function inpDe(racine, id) {
  return stub.findAll(racine, "INPUT").filter(function (i) { return i.id === id; })[0];
}
function selDe(racine, id) {
  return stub.findAll(racine, "SELECT").filter(function (s) { return s.id === id; })[0];
}
const fluxMoon = F("p2", "res:moon", "MoonLight", "udp", "47998,47999", "aller");
app.setState({
  acces: {groupes: [G("gaming", "Gaming", ["telephone"], [fluxMoon])],
          ressources: [{id: "moon", libelle: "MoonLight", cible: "192.168.1.18"}]},
  peers: [{name: "telephone"}], server: {}, time: 5
});
app.ouvrirNouvelleRegle({groupe: {id: "gaming", libelle: "Gaming"}, flux: fluxMoon});
const modR = env.doc.getElementById("dlg-body");
eq("les ports existants sont repris tels quels", inpDe(modR, "reg-ports").value, "47998,47999");
eq("la destination est reprise", selDe(modR, "reg-dst").value, "res:moon");
eq("le protocole est repris", selDe(modR, "reg-proto").value, "udp");
/* Le protocole etant UDP, les ports doivent rester saisissables : un pre-remplissage
   suivi d un champ grise aurait efface la liste que l on vient justement de montrer. */
eq("et les ports restent modifiables", inpDe(modR, "reg-ports").disabled, false);
/* Changer « qui » ne modifie pas la regle : cela en fait une autre. Le serveur ignore
   ce champ, la fenetre ne doit donc pas laisser croire qu il agit. */
eq("le groupe source est verrouillé", selDe(modR, "reg-src").disabled, true);
eq("et montre le groupe de la règle", selDe(modR, "reg-src").value, "gaming");

/* Une creation ordinaire ne doit evidemment rien avoir herite de tout cela. */
app.ouvrirNouvelleRegle();
const neuve = env.doc.getElementById("dlg-body");
eq("une création part toujours de champs vides", inpDe(neuve, "reg-ports").value, "");
eq("et son groupe source reste choisissable", selDe(neuve, "reg-src").disabled, false);

/* addEventListener appelle son auditeur avec l objet Event en PREMIER argument. Depuis
   que ces fonctions prennent un parametre, un cablage direct leur livrait cet Event — un
   objet bien vrai — et le bouton « Nouvelle ressource » ouvrait « Modifier la ressource »,
   nom verrouille et vide, vers /api/ressources/undefined/edit. Le cablage est repare, mais
   c est la FONCTION qu on teste : elle seule resiste au prochain copier-coller. */
app.ouvrirNouvelleRessource({type: "click", target: {}});
const faux = env.doc.getElementById("dlg-body");
contient("un objet qui n est pas une ressource ouvre la création",
         stub.textOf(faux), "Créer la ressource");
eq("et son champ nom reste saisissable", inpDe(faux, "res-id").disabled, false);
app.ouvrirNouvelleRegle({type: "click", target: {}});
const fauxR = env.doc.getElementById("dlg-body");
contient("de même pour une règle", stub.textOf(fauxR), "Créer la règle");

/* La ressource : son nom est la cle citee par les regles. Le renommer les ferait
   pointer dans le vide, alors que changer son adresse les deplace toutes en silence. */
app.ouvrirNouvelleRessource({id: "moon", libelle: "MoonLight", cible: "192.168.1.18",
                             mac: "aa:bb:cc:dd:ee:ff"});
const modS = env.doc.getElementById("dlg-body");
/* Le reveil a distance : sans MAC retenue, figer l association ARP serait a refaire a
   chaque redemarrage du Pi, et le Wake-on-LAN ne marcherait qu une fois. */
eq("la MAC du réveil est reprise", inpDe(modS, "res-mac").value, "aa:bb:cc:dd:ee:ff");
eq("l adresse de la ressource est reprise", inpDe(modS, "res-ip").value, "192.168.1.18");
eq("le nom est montré mais verrouillé", inpDe(modS, "res-id").disabled, true);
contient("et la fenêtre annonce ce que la modification entraîne",
         stub.textOf(modS), "pointera vers la nouvelle adresse");

/* --- l appareil pris entre deux reglages contradictoires ------------------- */
/* Le mode de routage (ce que l appareil ENVOIE) et les regles de son groupe (ce que le Pi
   LAISSE PASSER) sont deux choses differentes. Quand « tout le trafic » rencontre « aucune
   regle Internet », les noms se resolvent et aucune page ne charge. Rien ne le disait.
   La reponse est calculee en bash, pour « wg-pi check » comme pour le panneau : deux
   implementations de la meme regle finiraient par diverger. */
app.setState({
  acces: {groupes: [], ressources: [],
          avertissements: [{appareil: "telephone", groupes: "« Administration »"}]},
  peers: [{name: "telephone"}, {name: "pc-salon"}], server: {}, time: 6
});
eq("l appareil signalé par le moteur est reconnu", app.appareilSansInternet("telephone"), true);
eq("et les autres ne le sont pas", app.appareilSansInternet("pc-salon"), false);
/* Un etat sans la cle du tout — installation ancienne, reponse tronquee — ne doit pas
   faire tomber le rendu de la liste des appareils. */
app.setState({acces: {groupes: [], ressources: []}, peers: [], server: {}, time: 7});
eq("une absence de la clé ne casse rien", app.appareilSansInternet("telephone"), false);

/* --- modeles de regles ----------------------------------------------------- */
/* L ORDRE est un piege reel et non une precaution de style : majSens vide le champ des
   ports des que le protocole n est ni TCP ni UDP. Un modele qui ecrirait les ports AVANT
   le protocole les perdrait en silence, et l utilisateur verrait un champ vide apres
   avoir clique. On rejoue ici le comportement exact de majSens. */
const champsFaux = {
  proto: {value: "any"}, ports: {value: ""}, lib: {value: ""},
  maj: function () {
    if (champsFaux.proto.value !== "tcp" && champsFaux.proto.value !== "udp") {
      champsFaux.ports.value = "";
    }
  }
};
const moon = app.MODELES_REGLE.filter(function (m) { return m.cle === "moonlight"; })[0];
eq("Moonlight annonce deux règles", app.remplirModele(moon, champsFaux), 2);
eq("le protocole est posé en premier", champsFaux.proto.value, "tcp");
eq("et les ports survivent à la remise à jour", champsFaux.ports.value, "47984,47989,48010");
eq("un libellé est proposé", champsFaux.lib.value, "Moonlight (TCP)");

/* Un libelle deja saisi par l utilisateur ne doit pas etre ecrase : c est le sien. */
const dejaRempli = {proto: {value: "any"}, ports: {value: ""}, lib: {value: "Le mien"},
                    maj: function () {}};
app.remplirModele(moon, dejaRempli);
eq("un libellé déjà saisi est respecté", dejaRempli.lib.value, "Le mien");

/* « -m multiport » ne va pas au-dela de 15 ports, une plage en comptant pour deux. Un
   modele qui depasserait serait refuse a l ecriture, donc au clic — et le defaut ne se
   verrait qu une fois chez l utilisateur. On le verifie ici, pas a l execution. */
function budgetPorts(p) {
  return p.split(",").reduce(function (s, x) { return s + (x.indexOf("-") >= 0 ? 2 : 1); }, 0);
}
const formePorts = /^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$/;
const fautifs = [];
app.MODELES_REGLE.forEach(function (m) {
  if (!m.cle || !m.titre || !m.aide || !m.regles.length) { fautifs.push(m.cle + ":vide"); }
  m.regles.forEach(function (g) {
    if (budgetPorts(g.ports) > 15) { fautifs.push(m.cle + ":budget"); }
    /* Aucune espace : la validation cote serveur n en tolere pas une seule. */
    if (!formePorts.test(g.ports)) { fautifs.push(m.cle + ":forme"); }
    /* Des ports n ont de sens qu avec TCP, UDP ou les deux : le moteur refuse les autres. */
    if (g.proto !== "tcp" && g.proto !== "udp" && g.proto !== "tcpudp") { fautifs.push(m.cle + ":proto"); }
    if (g.libelle.length > 60 || g.libelle.indexOf("|") >= 0) { fautifs.push(m.cle + ":libelle"); }
  });
});
eq("tous les modèles tiennent dans les limites du moteur", fautifs.join(","), "");

/* Un modele ne doit imposer ni destination ni sens. Lui seul sait si Moonlight vise le PC
   du salon ou toute la maison ; et le sens est verrouille selon la destination, parce que
   hors « groupe » le trafic de retour ne repasse pas par le VPN. */
const imposent = app.MODELES_REGLE.filter(function (m) {
  return m.regles.some(function (g) { return g.destination || g.dest || g.sens; });
});
eq("aucun modèle n impose de destination ni de sens", imposent.length, 0);

/* Les modeles a deux regles sont ceux dont les ports TCP et UDP different : c est la
   raison d etre de la route de lot. Si cette liste tombait a zero, la route serait morte
   sans que rien ne le signale. */
const aDeux = app.MODELES_REGLE.filter(function (m) { return m.regles.length > 1; });
eq("au moins un modèle pose deux règles", aDeux.length > 0, true);
const memesPorts = aDeux.filter(function (m) { return m.regles[0].ports === m.regles[1].ports; });
eq("et leurs deux listes de ports diffèrent vraiment", memesPorts.length, 0);

/* --- le cablage de la route de lot ----------------------------------------- */
/* Tout ce qui precede verifie les DONNEES des modeles. Le branchement, lui, n etait
   couvert par rien : quelle route part, avec quel corps, et dans quels cas. C est pourtant
   la decision la plus delicate du formulaire — un lot envoye a tort cree une regle que
   l utilisateur n a pas vue, un lot non envoye lui en fait creer deux a la main. */
function soumettre(modele, retouche) {
  env.requetes.length = 0;
  env.etat.reponse = {status: 200, data: {ok: true}};
  app.setState({
    acces: {groupes: [G("gaming", "Gaming", ["telephone"])],
            ressources: [{id: "moon", libelle: "MoonLight", cible: "192.168.1.18"}]},
    peers: [{name: "telephone"}], server: {}, time: 9
  });
  app.ouvrirNouvelleRegle();
  const b = env.doc.getElementById("dlg-body");
  const form = stub.findAll(b, "FORM")[0];
  selDe(b, "reg-dst").value = "res:moon";
  form.dispatchEvent({type: "change", target: selDe(b, "reg-dst")});
  if (modele) {
    /* On clique le bouton du modele, par son libelle : c est ce que fait l utilisateur. */
    const bouton = stub.findAll(b, "BUTTON").filter(function (x) {
      return stub.textOf(x) === modele;
    })[0];
    if (!bouton) { return {erreur: "bouton « " + modele + " » introuvable"}; }
    bouton.dispatchEvent({type: "click"});
  }
  if (retouche) { retouche(b); }
  form.dispatchEvent({type: "submit"});
  return env.requetes[0] || {erreur: "aucune requete"};
}

/* Moonlight : deux regles, des ports differents par protocole. Le lot doit partir. */
const rLot = soumettre("Moonlight");
eq("le modele a deux regles part vers la route de lot", rLot.url, "/api/regles/lot");
eq("en POST", rLot.method, "POST");
eq("et le corps porte les deux regles", (rLot.body && rLot.body.regles || []).length, 2);
eq("la premiere en TCP", (rLot.body && rLot.body.regles || [{}])[0].proto, "tcp");
eq("la seconde en UDP", (rLot.body && rLot.body.regles || [{}, {}])[1].proto, "udp");
eq("les deux visent la meme destination",
   (rLot.body && rLot.body.regles || [{}, {}]).map(function (x) { return x.destination; }).join(","),
   "res:moon,res:moon");
/* Le jeton anti-CSRF part avec : sans lui le serveur refuse, et la fenetre resterait
   ouverte sur une erreur que personne ne saurait interpreter. */
eq("le jeton anti-CSRF accompagne la requete",
   typeof (rLot.entetes && rLot.entetes["X-CSRF-Token"]), "string");

/* Un modele a UNE seule regle passe par la route ordinaire : envoyer un lot d un element
   marcherait, mais la route ordinaire rend un message plus juste. */
const rSimple = soumettre("NAS");
eq("un modele a une seule regle passe par la route ordinaire", rSimple.url, "/api/regles");
eq("et son corps est une regle, pas une liste", rSimple.body && rSimple.body.regles, undefined);
eq("avec le protocole du modele", rSimple.body && rSimple.body.proto, "tcp");

/* Sans modele du tout : route ordinaire aussi. */
const rRien = soumettre(null);
eq("sans modele, route ordinaire", rRien.url, "/api/regles");

/* LE point delicat : des que l utilisateur retouche le protocole ou les ports, il ne voit
   plus ce que contient la seconde regle. En ajouter une a son insu serait pire que de lui
   en faire creer deux. Le lot est donc abandonne. */
const rRetouchePorts = soumettre("Moonlight", function (b) {
  inpDe(b, "reg-ports").value = "47984";
});
eq("des ports retouches abandonnent le lot", rRetouchePorts.url, "/api/regles");
eq("et la regle envoyee porte les ports de l utilisateur",
   rRetouchePorts.body && rRetouchePorts.body.ports, "47984");

const rRetoucheProto = soumettre("Moonlight", function (b) {
  selDe(b, "reg-proto").value = "udp";
});
eq("un protocole retouche abandonne le lot aussi", rRetoucheProto.url, "/api/regles");

/* Un libelle que l utilisateur a ecrit lui-meme doit se retrouver sur les DEUX regles du
   lot : sinon la seconde porterait un nom qu il n a pas choisi. */
const rLibelle = soumettre("Moonlight", function (b) {
  inpDe(b, "reg-lib").value = "Mon salon";
});
eq("un libelle saisi reste le lot", rLibelle.url, "/api/regles/lot");
eq("et il habille les deux regles",
   (rLibelle.body && rLibelle.body.regles || []).map(function (x) { return x.libelle; }).join("|"),
   "Mon salon|Mon salon");

/* Et le modele a deux protocoles sur les MEMES ports (« Jeu en reseau ») n est PAS un lot :
   une seule regle en tcpudp suffit, et le moteur en pose deux lignes. */
const rJeu = soumettre("Jeu en réseau");
eq("le modele a deux protocoles tient en une regle", rJeu.url, "/api/regles");
eq("portee par le protocole double", rJeu.body && rJeu.body.proto, "tcpudp");
eq("et ses ports survivent au verrouillage des champs",
   rJeu.body && rJeu.body.ports, "27015,27036");

console.log("");
console.log("  " + pass + " réussi(s), " + fail + " échoué(s)");
process.exit(fail === 0 ? 0 : 1);
