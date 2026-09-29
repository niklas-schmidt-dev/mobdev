/** Mac app releases live on GitHub; the site only points at the latest one. */
export const GITHUB_REPOSITORY = "niklas-schmidt-dev/mobdev";
export const GITHUB_URL = `https://github.com/${GITHUB_REPOSITORY}`;

export function latestAsset(name: string): string {
  return `${GITHUB_URL}/releases/latest/download/${name}`;
}
