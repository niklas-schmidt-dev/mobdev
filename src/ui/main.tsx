import React from 'react';
import ReactDOM from 'react-dom/client';
import '@fontsource/ibm-plex-sans/latin-400.css';
import '@fontsource/ibm-plex-sans/latin-500.css';
import '@fontsource/ibm-plex-sans/latin-600.css';
import '@fontsource/ibm-plex-mono/latin-400.css';
import { App } from './App';
import './styles.css';

class Boundary extends React.Component<React.PropsWithChildren, { error: string }> {
  state = { error: '' };
  static getDerivedStateFromError(error: Error) { return { error: error.message }; }
  render() { return this.state.error ? <main className="fatal"><h1>The workspace could not render.</h1><p>{this.state.error}</p><button onClick={() => location.reload()}>Reload workspace</button></main> : this.props.children; }
}
ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><Boundary><App /></Boundary></React.StrictMode>);
