"""More › Star Map (docs/spec/3x-morepages.md §17): GET /api/learning/graph[?profile=] and GET /api/learning/node.

Invented data, the same on every run (seeded). The shapes are the real gateway's (agent/learning_graph.py
`build_learning_graph`, agent/learning_mutations.py `node_detail`): skills as nodes with a category, memory entries as
cards AND as nodes of the category "memory", `related_skills` and memory-to-skill links as edges.

Knob:  POST /__fixture/graph {"nodes": N[, "edges": E][, "memory": M]}
  nodes   skills of the default bot: 60 at start and after a reset; 0 gives the empty graph (no memory either);
          2000 / 5000 for the stress runs. Every other bot gets a fixed share of N in fewer categories, so the bot
          picker visibly changes the map.
  edges   links between skills (default min(3000, 1.5 x N)); 10000 for the stress run
  memory  memory cards (default 40; card 3 is 20,000 characters long)
  delay   seconds every graph read waits before it answers (default 0)
  fail    {"status": 500, "count": 1}: the next `count` graph reads answer that status AFTER the delay (a slow read
          that then fails); the base fixture's /__fixture/fail can do either, not both
Every non-empty answer also carries three bad rows the app must skip: a second node with an id already listed, a node
without an id, and an edge to a node that is not there. The skill "retired-notes" is in every non-empty graph of the
default bot and its node answers 404.
"""
import hashlib, random, time

NEW = True
REST_PREFIXES = ('/api/learning',)

CATEGORIES = ['coding', 'research', 'writing', 'email', 'deploys', 'finance', 'calendar', 'data', 'design', 'devops',
              'support', 'travel']
WEIGHTS = [30, 12, 10, 8, 7, 6, 5, 5, 4, 3, 2, 2]
VERBS = ['review', 'summarize', 'draft', 'triage', 'ship', 'reconcile', 'plan', 'clean', 'sketch', 'watch', 'answer',
         'book', 'audit', 'compare', 'file', 'label', 'merge', 'rotate', 'trace', 'tidy']
NOUNS = ['pull-requests', 'papers', 'release-notes', 'inbox', 'builds', 'invoices', 'week', 'tables', 'mockups',
         'alerts', 'tickets', 'flights', 'logs', 'contracts', 'changelogs', 'threads', 'pipelines', 'receipts',
         'standups', 'dashboards']
SHARE = {'default': (1.0, 12), 'inbox': (0.4, 5), 'deploys': (0.7, 8), 'research': (0.25, 3), 'finance': (0.55, 6)}
MISSING = 'retired-notes'

knobs = {}
cache = {}
served = {'graph': 0, 'node': 0}


def seed():
    knobs.clear(); knobs.update(nodes=60, edges=None, memory=40, delay=0, fail=None)
    cache.clear()
    served.update(graph=0, node=0)


def cards(profile, count, rng):
    out = []
    for index in range(count):
        topic = NOUNS[(index * 7 + len(profile)) % len(NOUNS)].replace('-', ' ')
        title = f'{profile.title() if profile != "default" else "Hermes"} note {index + 1}: how the owner likes {topic}'
        body = title + '\n' + ' '.join(
            f'Keep {NOUNS[(index + step) % len(NOUNS)].replace("-", " ")} short and say what changed first.' for step in range(1 + index % 5))
        if index == 3:
            line = 'This is the long memory: every line of it is kept, and Show More unfolds it without a hitch. '
            body = title + '\n' + (line * (20000 // len(line) + 1))[:20000 - len(title) - 1]
        out.append({'source': 'profile' if index % 4 == 0 else 'memory', 'title': title, 'body': body,
                    'timestamp': 1757000000 + index * 86400,
                    'fingerprint': hashlib.sha256(body.encode()).hexdigest()[:12]})
    return out


def build(profile):
    share, kinds = SHARE.get(profile, (0.5, 6))
    count = int(round(knobs['nodes'] * share))
    rng = random.Random(f'star-map|{profile}|{count}')
    if count <= 0:
        return {'nodes': [], 'edges': [], 'clusters': [], 'memory': [],
                'stats': {'nodes': 0, 'related_edges': 0, 'memory_nodes': 0, 'learned_skills': 0}}
    categories, weights = CATEGORIES[:kinds], WEIGHTS[:kinds]
    names, nodes = set(), []
    if profile == 'default':
        names.add(MISSING)
        nodes.append({'id': MISSING, 'label': MISSING, 'kind': 'skill', 'timestamp': 1756000000, 'category': 'coding',
                      'useCount': 240, 'state': 'stale', 'createdBy': 'agent', 'pinned': True})
    while len(nodes) < count:
        name = f'{rng.choice(VERBS)}-{rng.choice(NOUNS)}'
        if name in names: name = f'{name}-{len(nodes)}'
        if name in names: continue
        names.add(name)
        used = 0 if rng.random() < 0.35 else int(min(180, rng.expovariate(1 / 14)) + 1)
        created = rng.choices(['agent', 'learn', None], [55, 15, 30])[0]
        if created is None and used == 0: used = 1 + rng.randrange(6)      # the gateway lists only skills with a learning signal
        nodes.append({'id': name, 'label': name, 'kind': 'skill', 'timestamp': 1750000000 + rng.randrange(8_000_000),
                      'category': categories[len(nodes)] if len(nodes) < len(categories) and len(nodes) < count else rng.choices(categories, weights)[0],
                      'useCount': used,
                      'state': rng.choices(['active', 'stale', 'archived'], [88, 8, 4])[0], 'createdBy': created,
                      'pinned': rng.random() < 0.08})
    skills = [n['id'] for n in nodes]
    by_category = {}
    for n in nodes: by_category.setdefault(n['category'], []).append(n['id'])

    wanted = knobs['edges'] if knobs['edges'] is not None else min(3000, int(count * 1.5))
    wanted = min(wanted, count * (count - 1) // 2)
    pairs, tries = set(), 0
    while len(pairs) < wanted and tries < wanted * 20:
        tries += 1
        a = rng.choice(skills)
        group = by_category[next(n['category'] for n in nodes if n['id'] == a)] if count <= 400 and rng.random() < 0.7 else skills
        b = rng.choice(group)
        if a != b: pairs.add((min(a, b), max(a, b)))
    edges = [{'source': a, 'target': b} for a, b in sorted(pairs)]

    memory = cards(profile, knobs['memory'], rng)
    for index, card in enumerate(memory):
        node_id = f'memory:{card["source"]}:{index}:{card["fingerprint"]}'
        nodes.append({'id': node_id, 'label': card['title'], 'kind': 'memory', 'memorySource': card['source'],
                      'timestamp': card['timestamp'], 'category': 'memory', 'useCount': 0, 'state': 'active',
                      'createdBy': 'memory', 'pinned': False})
        for target in rng.sample(skills, min(len(skills), 1 + index % 2)):
            edges.append({'source': node_id, 'target': target})

    clusters = {}
    for n in nodes: clusters[n['category']] = clusters.get(n['category'], 0) + 1
    # Bad rows the app must skip.
    nodes.insert(1, dict(nodes[0], label='a second copy of the first node'))
    nodes.insert(2, {'label': 'no id at all', 'kind': 'skill', 'category': 'coding', 'useCount': '3'})
    edges.append({'source': skills[0], 'target': 'not-a-node'})
    return {'nodes': nodes, 'edges': edges,
            'clusters': [{'category': c, 'count': k} for c, k in sorted(clusters.items(), key=lambda kv: -kv[1])],
            'memory': memory,
            'stats': {'nodes': count, 'related_edges': len(pairs), 'edges_per_node': round(len(pairs) / count, 3),
                      'memory_nodes': len(memory), 'memory_skill_edges': len(edges) - len(pairs) - 1, 'learned_skills': count}}


def graph(profile):
    key = (profile, knobs['nodes'], knobs['edges'], knobs['memory'])
    if key not in cache: cache[key] = build(profile)
    return cache[key]


def rest(method, path, query, body, handler):
    if not path.startswith('/api/learning/'): return None
    profile = ctx.one(query, 'profile') or 'default'
    if profile not in ctx.profiles(): return 404, {'detail': f"Unknown profile '{profile}'"}
    if path == '/api/learning/graph' and method == 'GET':
        if knobs['delay']: time.sleep(float(knobs['delay']))
        with ctx.lock:
            served['graph'] += 1
            fail = knobs['fail']
            if fail and int(fail.get('count', 1)) > 0:
                fail['count'] = int(fail.get('count', 1)) - 1
                return int(fail.get('status', 500)), {'detail': fail.get('detail', 'Failed to build learning graph')}
            return 200, graph(profile)
    if path == '/api/learning/node' and method == 'GET':
        node_id = ctx.one(query, 'id')
        with ctx.lock:
            served['node'] += 1
            found = graph(profile)
            node = next((n for n in found['nodes'] if n.get('id') == node_id), None)
            if node is None or node_id == MISSING: return 404, {'detail': f"skill '{node_id}' not found"}
            if node['kind'] == 'memory':
                index = int(node_id.split(':')[2])
                text = found['memory'][index]['body']
                return 200, {'ok': True, 'kind': 'memory', 'id': node_id, 'label': text.splitlines()[0][:80], 'content': text}
            words = node_id.replace('-', ' ')
            return 200, {'ok': True, 'kind': 'skill', 'id': node_id, 'label': node_id, 'content':
                         f'---\nname: {node_id}\ndescription: How to {words} the way the owner likes it.\ncategory: {node["category"]}\n---\n\n'
                         f'# {words.title()}\n\n1. Read what changed since the last time.\n2. {words.capitalize()} in small steps.\n'
                         f'3. Say what was done, and what is left.\n'}
    return None


def control(path, body):
    if path != '/__fixture/graph': return None
    with ctx.lock:
        if 'nodes' in body: knobs['nodes'] = max(0, int(body['nodes']))
        if 'edges' in body: knobs['edges'] = None if body['edges'] is None else max(0, int(body['edges']))
        if 'memory' in body: knobs['memory'] = max(0, int(body['memory']))
        if 'delay' in body: knobs['delay'] = max(0.0, float(body['delay'] or 0))
        if 'fail' in body: knobs['fail'] = dict(body['fail']) if isinstance(body['fail'], dict) else None
        cache.clear()
        return {'ok': True, **knobs}


def state(): return {'knobs': dict(knobs), 'served': dict(served)}


seed()
