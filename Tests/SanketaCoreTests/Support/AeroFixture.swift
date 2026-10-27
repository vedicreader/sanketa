let aeroSample = """
# a comment with = and ]
[gaps]
inner.horizontal = 8
[mode.main.binding]
cmd-alt-ctrl-shift-1 = 'workspace 1'   # go
alt-ctrl-shift-3 = 'move-node-to-workspace 3'
alt-ctrl-3 = 'move-node-to-workspace --focus-follows-window 3'
cmd-alt-ctrl-shift-w = 'move-node-to-workspace --wrap-around next'
cmd-alt-ctrl-shift-left = 'move left'
cmd-alt-ctrl-shift-r = 'mode resize'
cmd-alt-ctrl-shift-backtick = '''exec-and-forget echo a
echo b '''
cmd-alt-ctrl-shift-e = ['balance-sizes', 'mode main']
[mode.resize.binding]
minus = 'resize smart -50'
esc = 'mode main'
[[on-window-detected]]
if.app-id = 'x'
"""
