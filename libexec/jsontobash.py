#!/usr/bin/python3
# Convert json on stdin into bash variable settings on stdout.
# Lists made up of dictionaries including a 'name' key have an extra
#   variable defined listing the names.
# If command line parameter given, it will be the prefix on all the
#  variable names, default just an underscore.

import sys
import json

def collapsestr(item):
    if type(item) is dict and len(item) == 1 and next(iter(item.values())) is None:
        # special case for over-zealous yaml parsing of scope ending in colon
        key = next(iter(item.keys()))
        return(key + ':')
    return str(item)

def convertbash(pfx,data):
    if type(data) is dict:
        for key in data:
            convertbash(pfx + '_' + key, data[key])
    elif type(data) is list:
        if len(data) > 0 and type(data[0]) is dict and 'name' in data[0]:
            convertbash(pfx, ' '.join([item['name'] for item in data]))
            for item in data:
                name = item['name']
                del item['name']
                convertbash(pfx + '_' + name, item)
        else:
            convertbash(pfx, ' '.join([collapsestr(item) for item in data]))
    else:
        print(pfx + '="' + str(data) + '"')


def main():
    combined = json.load(sys.stdin)

    if len(sys.argv) > 1:
        convertbash(sys.argv[1], combined)
    else:
        convertbash("", combined)

if __name__ == '__main__':
    main()
