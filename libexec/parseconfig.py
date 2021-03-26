#!/usr/bin/python3

import os
import sys
import yaml
import json

prog = 'parseconfig.py'
dir = '/etc/htvault-config/config.d'

def efatal(msg, e, code=1):
    typ = type(e).__name__
    emsg = typ + ': ' + str(e)
    print(prog + ': ' + msg + ': ' + emsg, file=sys.stderr)
    sys.exit(code)

combined = {}

def merge(old, new):
    if type(new) is dict:
        if type(old) is not dict:
            raise Exception('type ' + str(type(new)) + ' does not match type ' + str(type(old)))
        for key in new:
            val = new[key]
            if key in old:
                old[key] = merge(old[key], new[key])
            else:
                old[key] = new[key]
        return old
    if type(new) is list:
        if type(old) is not list:
            raise Exception('type ' + str(type(new)) + ' does not match type ' + str(type(old)))
        combinedlist = []
        knownnames = {}
        for oldval in old:
            if type(oldval) is dict and 'name' in oldval:
                for newval in new:
                    if 'name' in newval and newval['name'] == oldval['name']:
                        knownnames = newval['name']
                        combinedlist.append(merge(oldval, newval))
        for newval in new:
            if type(newval) is not dict or 'name' in newval or newval['name'] not in knownnames:
                combinedlist.append(newval)
        return combinedlist
    return new


for f in sorted(os.listdir(dir)):
    if f[-5:] != '.yaml':
        continue
    filename = dir + '/' + f
    try:
        with open(filename) as fd:
            data = yaml.load(fd)
    except Exception as e:
        efatal('error loading yaml in ' + filename, e)
                 
    combined = merge(combined, data)

print(str(json.dumps(combined)))

