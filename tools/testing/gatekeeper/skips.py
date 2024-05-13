#!/usr/bin/env python3
#
# Copyright (c) 2024 Red Hat Inc.
#
# SPDX-License-Identifier: Apache-2.0

# Gets changes of the current git to env variable TARGET_BRANCH
# and reports feature skips in form of "skip_$feature=yes|no"
# or list of required tests (based on argv[1])

import os
import re
import subprocess
import sys
import yaml

from collections import OrderedDict


class Checks:
    def __init__(self):
        config_path = os.path.join(os.path.dirname(__file__), "required-tests.yaml")
        with open(config_path, "r", encoding="utf8") as config_fd:
            config = yaml.load(config_fd, Loader=yaml.SafeLoader)
        if config.get('required_tests'):
            self.required_tests = config['required_tests']
        else:
            self.required_tests = []
        if config.get('required_regexps'):
            self.required_regexps = config['required_regexps']
        else:
            self.required_regexps = []
        if config.get('paths'):
            self.paths = OrderedDict((re.compile(key), value)
                                       for items in config['paths']
                                       for key, value in items.items())
        if config.get('mapping'):
            self.mapping = config['mapping']
        else:
            self.mapping = {}
        self.all_set_of_tests = set(self.mapping.keys())

    def run(self, tests, target_branch):
        enabled_features = self.get_features(target_branch)
        if not tests:
            for feature in self.all_set_of_tests:
                print(f"skip_{feature}=" +
                      ('no' if feature in enabled_features else 'yes'))
            return 0
        required_tests = set(self.required_tests)
        required_regexps = set(self.required_regexps)
        for feature in enabled_features:
            values = self.mapping.get(feature, {})
            if values.get("names"):
                required_tests.update(values["names"])
            if values.get("regexps"):
                required_regexps.add(values["regexps"])
        print(';'.join(required_tests))
        print('|'.join(required_regexps))
        return 0

    def get_features(self, target_branch):
        """Check each changed file and find out to-be-tested features"""
        cmd = ["git", "diff", "--name-only", f"origin/{target_branch}"]
        changes = [_.decode("utf-8")
                   for _ in subprocess.check_output(cmd).split(b'\n')
                   if _.strip()]
        print('\n'.join(changes), file=sys.stderr)
        enabled_features = set()
        # Go through lines and find what features should be covered
        for line in changes:
            for regexp, features in self.paths.items():
                if regexp.search(line):
                    for feature in features:
                        enabled_features.add(feature)
                    break
            else:
                # Untreated line, run all tests
                return ALL_FEATURES
        return enabled_features


if __name__ == "__main__":
    if len(sys.argv) == 2:
        tests = sys.argv[1] == '-t'
    else:
        tests = False
    exit(Checks().run(tests, os.getenv("TARGET_BRANCH", "main")))
