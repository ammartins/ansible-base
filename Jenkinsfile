pipeline {
  agent any
  options {
    parallelsAlwaysFailFast()
  }
  stages {
    stage('Molecule Lint') {
      parallel {
        stage('Check Base') {
          steps {
            sh '''
              cd base
              molecule lint
            '''
          }
        }
      }
    }
    stage('Build docker image for Base') {
      steps {
        sh '''
          cd base
          sudo molecule converge
        '''
      }
    }
  }
}
