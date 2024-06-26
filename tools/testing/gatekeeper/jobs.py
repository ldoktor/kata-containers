#!/usr/bin/env python3
#
# Copyright (c) 2024 Red Hat Inc.
#
# SPDX-License-Identifier: Apache-2.0

# Keeps checking the current PR until all required jobs pass
# Env variables:
# * REQUIRED_JOBS: comma separated list of required jobs
# * REQUIRED_REGEXPS: comma separated list of regexps for required jobs
# * COMMIT_HASH: Full commit hash we want to be watching
# * GITHUB_REPOSITORY: Github repository (user/repo)
# Sample execution (GH token can be excluded):
# GITHUB_TOKEN="..." REQUIRED_JOBS="skipper / skipper"
# REQUIRED_REGEXPS=".*build-asset.*"
# COMMIT_HASH=11fad8c4a16f71c57ab1808755eecef19e14d7af
# GITHUB_REPOSITORY=kata-containers/kata-containers
# python3 jobs.py

import os
import re
import sys
import time
import requests


PASS = 0
FAIL = 1
RUNNING = 127


_GH_HEADERS = {"Accept": "application/vnd.github.v3+json"}
if os.environ.get("GITHUB_TOKEN"):
    _GH_HEADERS["Authorization"] = f"token {os.environ['GITHUB_TOKEN']}"
_GH_RUNS_URL = ("https://api.github.com/repos/"
                f"{os.environ['GITHUB_REPOSITORY']}/actions/runs")


class Checker:
    """Object to keep watching required GH action workflows"""
    def __init__(self):
        required_jobs = os.getenv("REQUIRED_JOBS")
        if required_jobs:
            required_jobs = required_jobs.split(",")
        else:
            required_jobs = []
        required_regexps = os.getenv("REQUIRED_REGEXPS")
        self.required_regexps = []
        # TODO: Add way to specify minimum amount of tests
        # (eg. via \d+: prefix) and check it in status
        if required_regexps:
            for regexp in required_regexps.split(","):
                self.required_regexps.append(re.compile(regexp))
        if not required_jobs and not self.required_regexps:
            raise RuntimeError("No REQUIRED_JOBS or REQUIRED_REGEXPS defined")
        self.results = {job: {} for job in required_jobs}

    def record(self, workflow_id, job):
        """
        Record a job run

        :returns: True on pending job, False on finished jobs
                  (successful or not)
        """
        job_name = job["name"]
        if job_name not in self.results:
            for re_job in self.required_regexps:
                # Required job via regexp
                if re_job.match(job_name):
                    self.results[job_name] = {}
                    break
            else:
                # Not a required job
                return False
        if job["status"] != "completed":
            self.results[job_name][workflow_id] = RUNNING
            return True
        if job["conclusion"] != "success":
            self.results[job_name][workflow_id] = job['conclusion']
            return False
        self.results[job_name][workflow_id] = PASS
        return False

    def status(self):
        """
        :returns: 0 - all tests passing; 127 - no failures but some
            tests in progress; 1 - any failure
        """
        running = False
        if not self.results:
            # No results reported so far
            return FAIL
        for result in self.results.values():
            if not result:
                # Status not reported yet
                running |= True
                continue
            for stat in result.values():
                if stat == RUNNING:
                    running |= True
                elif stat != PASS:
                    # Status not passed
                    return FAIL
        if running:
            return RUNNING
        return PASS

    def __str__(self):
        """Print status"""
        out = []
        for job, status in self.results.items():
            if not status:
                out.append(f"WARN: {job} - No results so far")
                continue
            for workflow, stat in status.items():
                if stat == RUNNING:
                    out.append(f"WARN: {workflow}/{job} - Still running")
                elif stat == PASS:
                    out.append(f"PASS: {workflow}/{job} - success")
                else:
                    out.append(f"FAIL: {workflow}/{job} - Not passed - {stat}")
        out = "\n".join(sorted(out))
        stat = self.status()
        if stat == RUNNING:
            status = "Some jobs are still running."
        elif stat == PASS:
            status = "All required jobs passed"
        else:
            status = "Not all required jobs passed!"
        return f"{out}\n\n{status}"

    def get_jobs_for_workflow_run(self, run_id):
        """Get jobs from a workflow id"""
        total_count = -1
        jobs = []
        page = 1
        while True:
            response = requests.get(
                f"{_GH_RUNS_URL}/{run_id}/jobs?per_page=100&page={page}",
                headers=_GH_HEADERS,
                timeout=60
            )
            response.raise_for_status()
            output = response.json()
            jobs.extend(output["jobs"])
            total_count = max(total_count, output["total_count"])
            if len(jobs) >= total_count:
                break
            page += 1
        return jobs

    def check_workflow_runs_status(self):
        """
        Checks if all required jobs passed

        :returns: 0 - all passing; 1 - any failure; 127 some jobs running
        """
        # TODO: Check if we need pagination here as well
        latest_commit_sha = os.getenv("COMMIT_HASH")
        response = requests.get(
            _GH_RUNS_URL,
            params={"head_sha": latest_commit_sha},
            headers=_GH_HEADERS,
            timeout=60
        )
        response.raise_for_status()
        workflow_runs = response.json()["workflow_runs"]

        for run in workflow_runs:
            jobs = self.get_jobs_for_workflow_run(run["id"])
            for job in jobs:
                self.record(run["name"], job)
        print(self)
        return self.status()

    def run(self):
        """
        Keep checking the PR until all required jobs finish

        :returns: 0 on success; 1 on failure
        """
        while True:
            ret = self.check_workflow_runs_status()
            if ret == RUNNING:
                time.sleep(60)
                continue
            sys.exit(ret)


if __name__ == "__main__":
    Checker().run()
