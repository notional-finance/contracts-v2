import scripts.deploy_v1
import scripts.deployment


def main():
    v2env = scripts.deployment.main()
    scripts.deploy_v1.deploy_v1(v2env)
